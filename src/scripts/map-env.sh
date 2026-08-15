#!/bin/bash
set -uo pipefail

# Maps CircleCI's job-context environment variables onto their documented Buildkite
# equivalents (buildkite.com/docs/pipelines/configure/environment-variables) and
# exports the result into $BASH_ENV. Variables that require a real Buildkite account
# / control plane (BUILDKITE_AGENT_ACCESS_TOKEN, BUILDKITE_AGENT_ENDPOINT, ...) have no
# CircleCI equivalent and are deliberately left unset - see the README.

export_var() {
    # export_var NAME VALUE - writes a shell-safe `export NAME=VALUE` line to
    # $BASH_ENV and applies it to this process too.
    local name="$1" value="$2" quoted
    printf -v quoted '%q' "${value}"
    echo "export ${name}=${quoted}" >> "${BASH_ENV}"
    export "${name}=${value}"
}

pr_number() {
    # CIRCLE_PULL_REQUEST is a full URL, e.g. https://github.com/org/repo/pull/123.
    # BUILDKITE_PULL_REQUEST is just the number, or the string "false" if not a PR.
    if [[ -n "${CIRCLE_PULL_REQUEST:-}" ]]; then
        echo "${CIRCLE_PULL_REQUEST##*/}"
    else
        echo "false"
    fi
}

pipeline_provider() {
    case "${CIRCLE_REPOSITORY_URL:-}" in
        *github.com*) echo "github" ;;
        *bitbucket.org*) echo "bitbucket" ;;
        *gitlab.com*) echo "gitlab" ;;
        *) echo "unknown" ;;
    esac
}

# Reserved shell/interpreter-control variable names that `extra-env` must never be
# allowed to overwrite. extra-env is exported into $BASH_ENV, which every later step in
# the job sources - an entry like "PATH=./evilbin:/usr/bin:/bin" or
# "BASH_ENV=/tmp/pwned.sh" would otherwise rewrite the shell environment for every
# subsequent step in the job. This is the same class of denylist the sibling
# bitbucket-pipes-orb's map-env.sh (RESERVED_SHELL_VAR_NAMES) and harness-orb's
# collect-outputs.sh already carry; buildkite-orb's map-env.sh did not have one until
# this pass closed the gap (see the release-readiness audit's "coverage-gap-that-
# reveals-a-behavior-gap" finding). Kept as an identical list to bitbucket's for
# consistency across this orb family.
RESERVED_SHELL_VAR_NAMES=(
    PATH IFS BASH_ENV ENV SHELL SHELLOPTS PS4
    LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH
    NODE_OPTIONS GIT_SSH_COMMAND PERL5LIB PYTHONPATH RUBYOPT CDPATH
)
is_reserved_shell_var_name() {
    local candidate="$1" reserved
    for reserved in "${RESERVED_SHELL_VAR_NAMES[@]}"; do
        if [[ "${candidate}" == "${reserved}" ]]; then
            return 0
        fi
    done
    return 1
}

export_var BUILDKITE "true"
export_var BUILDKITE_AGENT_NAME "circleci"
export_var BUILDKITE_PIPELINE_PROVIDER "$(pipeline_provider)"
export_var BUILDKITE_BUILD_CHECKOUT_PATH "${CIRCLE_WORKING_DIRECTORY:-$(pwd)}"
export_var BUILDKITE_BRANCH "${CIRCLE_BRANCH:-}"
export_var BUILDKITE_COMMIT "${CIRCLE_SHA1:-}"
export_var BUILDKITE_TAG "${CIRCLE_TAG:-}"
export_var BUILDKITE_PULL_REQUEST "$(pr_number)"
export_var BUILDKITE_ORGANIZATION_SLUG "${CIRCLE_PROJECT_USERNAME:-}"
export_var BUILDKITE_PIPELINE_SLUG "${CIRCLE_PROJECT_REPONAME:-}"
export_var BUILDKITE_BUILD_NUMBER "${CIRCLE_BUILD_NUM:-}"
export_var BUILDKITE_BUILD_ID "${CIRCLE_WORKFLOW_ID:-}"
export_var BUILDKITE_JOB_ID "${CIRCLE_WORKFLOW_JOB_ID:-}"
export_var BUILDKITE_REPO "${CIRCLE_REPOSITORY_URL:-}"
export_var BUILDKITE_BUILD_URL "${CIRCLE_BUILD_URL:-}"

if [[ -n "${ORB_VAL_EXTRA_ENV}" ]]; then
    RAW_EXTRA_ENV="${ORB_VAL_EXTRA_ENV}"
    if command -v circleci > /dev/null 2>&1; then
        RAW_EXTRA_ENV="$(circleci env subst <<< "${ORB_VAL_EXTRA_ENV}")"
    else
        echo "map-env: 'circleci' CLI not found on PATH - applying extra-env without \$VAR substitution." >&2
    fi
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" != *"="* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        # CircleCI's default `-e` run-step shell means a failing `export` here would
        # abort this whole script mid-loop - after it had already written the bad line
        # to $BASH_ENV, which would then break every later step's shell startup too (each
        # one sources $BASH_ENV). Validate the key is a legal bash identifier BEFORE
        # calling export_var, and skip (loudly) rather than crash or silently rewrite the
        # name the user asked for.
        if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "map-env: skipping extra-env entry '${line}' - '${key}' is not a legal environment variable name (must match [A-Za-z_][A-Za-z0-9_]*)." >&2
            continue
        fi
        if is_reserved_shell_var_name "${key}"; then
            echo "map-env: skipping extra-env entry '${line}' - '${key}' is a reserved shell/interpreter-control variable; refusing to let extra-env overwrite it for every later step in this job." >&2
            continue
        fi
        export_var "${key}" "${value}"
    done <<< "${RAW_EXTRA_ENV}"
fi

echo "Mapped CircleCI job context onto BUILDKITE_* environment variables."
