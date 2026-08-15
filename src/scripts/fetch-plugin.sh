#!/bin/bash
set -euo pipefail

# Resolves a Buildkite plugin reference to a git URL + ref (+ optional in-repo
# subdirectory), clones it, and derives the BUILDKITE_PLUGIN_<NAME>_ env-var prefix
# following the same naming rules Buildkite documents and real plugin repos rely on
# (buildkite.com/docs/pipelines/integrations/plugins/using,
# buildkite.com/docs/pipelines/integrations/plugins/writing), independently observed
# against real plugin repos:
#
#   1. The name is taken from the repository (or subdirectory) name, NOT the
#      `name:` field inside plugin.yml.
#   2. A trailing "-buildkite-plugin" suffix is stripped.
#   3. The result is uppercased and any hyphens/spaces become underscores.
#   4. A plugin referenced by a full git URL whose repo does not end in
#      "-buildkite-plugin" gets "_GIT" appended to the derived name.
#
# Supported reference forms (matching Buildkite's own documented plugin sources):
#   name#ref                    -> github.com/buildkite-plugins/<name>-buildkite-plugin
#   org/name#ref                -> github.com/org/<name>-buildkite-plugin
#   https://.../repo.git#ref
#   ssh://git@.../repo.git#ref
#   file:///path/repo.git#ref
#   https://.../repo.git/subdir#ref   (subdirectory plugin)
# git@host:org/repo.git style (scp syntax) is NOT a documented Buildkite plugin
# source and is not accepted here - use an explicit ssh:// URL instead.

PLUGIN_REF="${ORB_VAL_PLUGIN}"
PLUGIN_DIR="${ORB_VAL_PLUGIN_DIR}"
ALWAYS_CLONE_FRESH="${ORB_VAL_ALWAYS_CLONE_FRESH}"

if [[ -z "${PLUGIN_REF}" ]]; then
    echo "fetch-plugin: the 'plugin' parameter is required." >&2
    exit 1
fi

# Passed through `circleci env subst` first, like `configure`'s config and `map-env`'s
# extra-env, so a private-repo reference can embed a credential as "$MY_TOKEN" (e.g.
# "https://oauth2:$MY_TOKEN@github.com/org/priv-buildkite-plugin.git#v1") without that
# secret's value ever appearing in the CircleCI config itself. The plugin reference
# string is still passed through to git VERBATIM after substitution - no version
# resolution logic of any kind is applied.
if command -v circleci > /dev/null 2>&1; then
    PLUGIN_REF="$(circleci env subst <<< "${PLUGIN_REF}")"
else
    echo "fetch-plugin: 'circleci' CLI not found on PATH - using the plugin reference as-is, without \$VAR substitution." >&2
fi

# redact_userinfo TEXT - masks every "user:pass@" (or "user@") URL-userinfo prefix in TEXT
# before a build log ever sees it, so a credential embedded directly in a plugin git URL isn't
# echoed in plain text. Deliberately NOT anchored to the start of the string (no `^`) and
# global (`g`): the two original call sites only ever passed a bare URL, where an anchored,
# single-match pattern was enough, but git's own fatal clone-error text embeds the URL
# mid-message (and sometimes more than once) - see the retry path below, where this same
# function is applied to a real `git clone` stderr capture, not just a bare URL string.
redact_userinfo() {
    printf '%s' "$1" | sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1***REDACTED***@#g'
}

format_env_key() {
    # Uppercase, then hyphens/spaces -> underscores.
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[- ]/_/g'
}

sanitize_name() {
    # Lowercase, then collapse anything that isn't [a-z0-9-] into a single hyphen.
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

# --- Split off the #ref suffix, if any. ---
if [[ "${PLUGIN_REF}" == *"#"* ]]; then
    REF="${PLUGIN_REF##*#}"
    LOCATION="${PLUGIN_REF%#*}"
else
    REF=""
    LOCATION="${PLUGIN_REF}"
fi

# REF reaches `git checkout "${REF}"` (no `--` separator - see below) as a bare
# argument. A REF starting with `-` would be parsed by git as an OPTION rather than a
# ref - e.g. "--orphan=pwned" would make git create a new orphan branch instead of
# checking anything out, silently (exit 0) landing PLUGIN_ROOT on the wrong content
# instead of failing loudly. No legitimate git ref name can start with `-` (git itself
# refuses to create one via `git branch -- -name`), so reject it outright rather than
# trying to shell-escape around it - a `--` separator on `checkout` would "fix" the
# injection but also breaks checking out a perfectly normal tag/branch/SHA, because
# `checkout -- <ref>` is git's "restore this pathspec" form, not "switch to this ref".
if [[ -n "${REF}" && "${REF}" == -* ]]; then
    echo "fetch-plugin: the ref '${REF}' in plugin reference '${PLUGIN_REF}' is not a valid git ref (refs cannot start with '-') - refusing to pass it to git." >&2
    exit 1
fi

NEEDS_GIT_SUFFIX=false
SUBDIR=""

case "${LOCATION}" in
    https://* | http://* | ssh://* | file://*)
        # Full git URL, optionally with a subdirectory after a ".git/" path component.
        if [[ "${LOCATION}" == *".git/"* ]]; then
            REPO_URL="${LOCATION%.git/*}.git"
            SUBDIR="${LOCATION#*.git/}"
        else
            REPO_URL="${LOCATION}"
            SUBDIR=""
        fi

        if [[ -n "${SUBDIR}" ]]; then
            # UNVERIFIED ASSUMPTION: Buildkite's own docs never state whether the
            # derived <NAME> for a subdirectory plugin ("repo.git/subdir#ref") comes
            # from the subdirectory's own name or the outer repo's name - no real
            # multi-plugin monorepo example was found to confirm either way. This uses
            # the subdirectory name (the more specific, and so more plugin-identifying,
            # of the two) - flag and fix this if a real example proves otherwise.
            RAW_NAME="${SUBDIR##*/}"
        else
            BASE_NAME="${REPO_URL##*/}"
            RAW_NAME="${BASE_NAME%.git}"
        fi

        if [[ "${RAW_NAME}" == *-buildkite-plugin ]]; then
            DERIVED_NAME="${RAW_NAME%-buildkite-plugin}"
        else
            DERIVED_NAME="${RAW_NAME}"
            NEEDS_GIT_SUFFIX=true
        fi
        ;;
    *)
        # org/name or bare name shorthand (bare name only resolves under buildkite-plugins).
        if [[ "${LOCATION}" == */* ]]; then
            ORG="${LOCATION%%/*}"
            NAME="${LOCATION#*/}"
        else
            ORG="buildkite-plugins"
            NAME="${LOCATION}"
        fi
        REPO_URL="https://github.com/${ORG}/${NAME}-buildkite-plugin.git"
        DERIVED_NAME="${NAME}"
        ;;
esac

DERIVED_NAME_LC="$(sanitize_name "${DERIVED_NAME}")"
ENV_NAME="$(format_env_key "${DERIVED_NAME_LC}")"
if [[ "${NEEDS_GIT_SUFFIX}" == "true" ]]; then
    ENV_NAME="${ENV_NAME}_GIT"
fi
ENV_PREFIX="BUILDKITE_PLUGIN_${ENV_NAME}"

echo "Resolved plugin reference '$(redact_userinfo "${PLUGIN_REF}")':"
echo "  repo:   $(redact_userinfo "${REPO_URL}")"
echo "  ref:    ${REF:-<none - cloning default branch>}"
echo "  subdir: ${SUBDIR:-<none>}"
echo "  env prefix: ${ENV_PREFIX}_"

if [[ -z "${REF}" ]]; then
    echo "WARNING: no #ref pinned on this plugin reference. Buildkite recommends always pinning to a tag or commit SHA to avoid unexpected changes and stale checkouts." >&2
fi

mkdir -p "${PLUGIN_DIR}"
CLONE_TARGET="${PLUGIN_DIR}/_repo"
RESOLVED_REF_FILE="${PLUGIN_DIR}/_resolved_ref"

# A cached/existing clone is only reusable if it's a clone of THIS SAME reference -
# e.g. save_cache/restore_cache restored a prior run's clone under the same
# plugin-dir, or an earlier step in this job already fetched this exact plugin. If
# plugin-dir previously held a *different* plugin (most likely: a job called
# fetch-plugin more than once against the same default plugin-dir), always-clone-fresh
# alone wouldn't catch that - so re-clone whenever the resolved reference differs, too.
if [[ -d "${CLONE_TARGET}/.git" ]] &&
    [[ "${ALWAYS_CLONE_FRESH}" != "true" && "${ALWAYS_CLONE_FRESH}" != "1" ]] &&
    [[ -f "${RESOLVED_REF_FILE}" ]] &&
    [[ "$(cat "${RESOLVED_REF_FILE}")" == "${PLUGIN_REF}" ]]; then
    echo "Using cached/existing clone at ${CLONE_TARGET}"
else
    rm -rf "${CLONE_TARGET}"
    if [[ -n "${REF}" ]]; then
        if ! git clone --quiet --depth 1 --branch "${REF}" "${REPO_URL}" "${CLONE_TARGET}" 2> /tmp/.bk-clone-err.log; then
            echo "Shallow clone by ref '${REF}' didn't work (it may be a commit SHA rather than a branch or tag) - retrying with a full clone."
            # git's own fatal message routinely echoes the URL it was cloning verbatim - for
            # the documented private-repo pattern (https://oauth2:$TOKEN@host/...) that means
            # the credential itself, in plain text, on a real auth failure/wrong ref/transient
            # network error (routine, not exotic). Redact it the same way the two deliberate
            # "Resolved plugin reference"/"repo:" lines above already are, before printing.
            redact_userinfo "$(cat /tmp/.bk-clone-err.log)" >&2 || true
            rm -rf "${CLONE_TARGET}"
            # The retry's own full clone can fail too (same credential, same server, most
            # likely the same auth failure) - its stderr needs the identical redaction
            # treatment, not just the first attempt's. Captured and redacted the same way,
            # rather than let git print directly to this step's stderr unredacted.
            if ! git clone --quiet "${REPO_URL}" "${CLONE_TARGET}" 2> /tmp/.bk-clone-err.log; then
                redact_userinfo "$(cat /tmp/.bk-clone-err.log)" >&2 || true
                exit 1
            fi
            git -C "${CLONE_TARGET}" checkout --quiet "${REF}"
        fi
    else
        git clone --quiet --depth 1 "${REPO_URL}" "${CLONE_TARGET}"
    fi
    echo "${PLUGIN_REF}" > "${RESOLVED_REF_FILE}"
fi

if [[ -n "${SUBDIR}" ]]; then
    PLUGIN_ROOT="${CLONE_TARGET}/${SUBDIR}"
    # SUBDIR comes straight from the plugin reference's "...git/<subdir>#ref" form and
    # is used unsanitized above - a reference like
    # "https://github.com/org/repo.git/../../etc#main" would otherwise resolve
    # PLUGIN_ROOT to somewhere outside CLONE_TARGET entirely (e.g. /tmp/etc), and
    # run-hooks would then look for hooks/* at that arbitrary filesystem location.
    # Canonicalize and verify the result is still inside the clone before trusting it.
    RESOLVED_PLUGIN_ROOT="$(realpath -m -- "${PLUGIN_ROOT}")"
    RESOLVED_CLONE_TARGET="$(realpath -m -- "${CLONE_TARGET}")"
    case "${RESOLVED_PLUGIN_ROOT}" in
        "${RESOLVED_CLONE_TARGET}" | "${RESOLVED_CLONE_TARGET}"/*) ;;
        *)
            echo "fetch-plugin: subdirectory '${SUBDIR}' resolves to '${RESOLVED_PLUGIN_ROOT}', outside the cloned plugin repository at '${RESOLVED_CLONE_TARGET}' - refusing to use it." >&2
            exit 1
            ;;
    esac
    PLUGIN_ROOT="${RESOLVED_PLUGIN_ROOT}"
else
    PLUGIN_ROOT="${CLONE_TARGET}"
fi

if [[ ! -f "${PLUGIN_ROOT}/plugin.yml" ]]; then
    echo "WARNING: no plugin.yml found at ${PLUGIN_ROOT}. Continuing anyway - hooks will still run if present, but there is no schema to validate config against." >&2
fi

# check_requirements PLUGIN_YML - plugin.yml can declare a top-level `requirements:`
# list of command names its hooks assume are already on $PATH (e.g. vault, aws, jq).
# Real buildkite-agent never installs these either - they're an assumption about the
# host - so a missing one normally surfaces as a confusing failure deep inside a hook
# ("vault: command not found"). Warn up front instead, naming exactly what's missing,
# so the real cause is obvious immediately rather than a mystery to debug. Deliberately
# a warning, not a hard failure: a hook may only need a listed requirement on a code
# path this particular run doesn't take, so refusing to even try would be too strict.
check_requirements() {
    local plugin_yml="$1"
    [[ -f "${plugin_yml}" ]] || return 0
    local in_block=false line item
    local -a missing=()
    while IFS= read -r line; do
        if [[ "${in_block}" == "false" ]]; then
            [[ "${line}" == "requirements:"* ]] && in_block=true
            continue
        fi
        if [[ "${line}" =~ ^[[:space:]]*-[[:space:]]*(.+)[[:space:]]*$ ]]; then
            item="${BASH_REMATCH[1]}"
            item="$(strip_quotes "${item}")"
            command -v "${item}" > /dev/null 2>&1 || missing+=("${item}")
        elif [[ -n "${line}" ]]; then
            in_block=false
        fi
    done < "${plugin_yml}"
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "fetch-plugin: WARNING: this plugin's plugin.yml lists 'requirements:' not found on \$PATH: ${missing[*]}. Buildkite agents never install these either - install them yourself (or switch to an image/executor that has them) before hooks that need them run, or expect a less obvious failure from deep inside a hook script." >&2
    fi
}

strip_quotes() {
    local v="$1"
    if [[ "${v}" =~ ^\"(.*)\"$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "${v}" =~ ^\'(.*)\'$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "${v}"
    fi
}

check_requirements "${PLUGIN_ROOT}/plugin.yml"

if [[ -d "${PLUGIN_ROOT}/hooks" ]]; then
    chmod +x "${PLUGIN_ROOT}"/hooks/* 2> /dev/null || true
fi

{
    echo "export BUILDKITE_PLUGIN_ROOT='${PLUGIN_ROOT}'"
    echo "export BUILDKITE_PLUGIN_ENV_PREFIX='${ENV_PREFIX}'"
    echo "export BUILDKITE_PLUGIN_NAME='${ENV_NAME}'"
} >> "${BASH_ENV}"

export BUILDKITE_PLUGIN_ROOT="${PLUGIN_ROOT}"
export BUILDKITE_PLUGIN_ENV_PREFIX="${ENV_PREFIX}"
export BUILDKITE_PLUGIN_NAME="${ENV_NAME}"

echo "Plugin ready at ${PLUGIN_ROOT}"
