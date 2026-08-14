#!/bin/bash
set -euo pipefail

# Resolves a Buildkite plugin reference to a git URL + ref (+ optional in-repo
# subdirectory), clones it, and derives the BUILDKITE_PLUGIN_<NAME>_ env-var prefix
# using the same algorithm buildkite-agent uses (see agent/plugin/plugin.go):
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

format_env_key() {
  # Uppercase, then hyphens/spaces -> underscores. Mirrors formatEnvKey() exactly.
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

NEEDS_GIT_SUFFIX=false
SUBDIR=""

case "${LOCATION}" in
  https://*|http://*|ssh://*|file://*)
    # Full git URL, optionally with a subdirectory after a ".git/" path component.
    if [[ "${LOCATION}" == *".git/"* ]]; then
      REPO_URL="${LOCATION%.git/*}.git"
      SUBDIR="${LOCATION#*.git/}"
    else
      REPO_URL="${LOCATION}"
      SUBDIR=""
    fi

    if [[ -n "${SUBDIR}" ]]; then
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

echo "Resolved plugin reference '${PLUGIN_REF}':"
echo "  repo:   ${REPO_URL}"
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
if [[ -d "${CLONE_TARGET}/.git" ]] \
  && [[ "${ALWAYS_CLONE_FRESH}" != "true" && "${ALWAYS_CLONE_FRESH}" != "1" ]] \
  && [[ -f "${RESOLVED_REF_FILE}" ]] \
  && [[ "$(cat "${RESOLVED_REF_FILE}")" == "${PLUGIN_REF}" ]]; then
  echo "Using cached/existing clone at ${CLONE_TARGET}"
else
  rm -rf "${CLONE_TARGET}"
  if [[ -n "${REF}" ]]; then
    if ! git clone --quiet --depth 1 --branch "${REF}" "${REPO_URL}" "${CLONE_TARGET}" 2>/tmp/.bk-clone-err.log; then
      echo "Shallow clone by ref '${REF}' didn't work (it may be a commit SHA rather than a branch or tag) - retrying with a full clone."
      cat /tmp/.bk-clone-err.log >&2 || true
      rm -rf "${CLONE_TARGET}"
      git clone --quiet "${REPO_URL}" "${CLONE_TARGET}"
      git -C "${CLONE_TARGET}" checkout --quiet "${REF}"
    fi
  else
    git clone --quiet --depth 1 "${REPO_URL}" "${CLONE_TARGET}"
  fi
  echo "${PLUGIN_REF}" > "${RESOLVED_REF_FILE}"
fi

if [[ -n "${SUBDIR}" ]]; then
  PLUGIN_ROOT="${CLONE_TARGET}/${SUBDIR}"
else
  PLUGIN_ROOT="${CLONE_TARGET}"
fi

if [[ ! -f "${PLUGIN_ROOT}/plugin.yml" ]]; then
  echo "WARNING: no plugin.yml found at ${PLUGIN_ROOT}. Continuing anyway - hooks will still run if present, but there is no schema to validate config against." >&2
fi

if [[ -d "${PLUGIN_ROOT}/hooks" ]]; then
  chmod +x "${PLUGIN_ROOT}"/hooks/* 2>/dev/null || true
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
