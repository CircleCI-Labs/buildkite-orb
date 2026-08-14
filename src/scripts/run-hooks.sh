#!/bin/bash
set -uo pipefail
# Deliberately no `set -e` at the top level: this script must keep running past a
# failing hook so it can still run pre-exit and compute the right final exit code -
# mirroring buildkite-agent's own lifecycle, not bash's default abort-on-error.

PLUGIN_ROOT="${BUILDKITE_PLUGIN_ROOT:-}"
FALLBACK_COMMAND="${ORB_VAL_COMMAND}"
WORKDIR="${ORB_VAL_WORKING_DIRECTORY}"

if [[ -z "${PLUGIN_ROOT}" ]]; then
    echo "run-hooks: \$BUILDKITE_PLUGIN_ROOT is not set. Run the fetch-plugin command/step before run-hooks." >&2
    exit 1
fi

mkdir -p "${WORKDIR}"
cd "${WORKDIR}" || exit 1

IFS=',' read -ra HOOK_ORDER <<< "${ORB_VAL_HOOKS}"
hook_listed() {
    local want="$1" h
    for h in "${HOOK_ORDER[@]}"; do
        [[ "${h}" == "${want}" ]] && return 0
    done
    return 1
}

# Bash-internal / bookkeeping variables that must never be threaded between hooks -
# PWD/OLDPWD are handled explicitly via BUILDKITE_HOOK_WORKING_DIR instead (matching
# Buildkite's own documented behaviour: a hook that cd's persists that cd to the next
# hook and to the command), and re-exporting them as plain values would fight with
# bash's own automatic PWD/OLDPWD management.
EXCLUDE_RE='^declare -x (PWD|OLDPWD|_|SHLVL|BASH_ENV)='

# run_hook_file HOOK_PATH
# Runs the hook in its own bash process, dumping the exported-variable set before and
# after (via `export -p`, which - unlike plain `env` - correctly quotes multi-line and
# special-character values). Diffs the two dumps and applies the diff to *this* shell
# and to $BASH_ENV, then follows the hook's own final working directory. Returns the
# hook process's exit status.
run_hook_file() {
    local hook_path="$1"
    local before after wrapper exit_code

    before="$(mktemp)"
    after="$(mktemp)"
    wrapper="$(mktemp)"

    # These printf format strings are the CONTENTS of the wrapper script we're
    # generating, not commands to run now - $__bk_hook_exit/$PWD are deliberately left
    # unexpanded here so they're evaluated later, inside the wrapper, after the hook runs.
    # shellcheck disable=SC2016
    {
        printf '#!/bin/bash\n'
        printf 'export -p > %q\n' "${before}"
        printf '. %q\n' "${hook_path}"
        printf '__bk_hook_exit=$?\n'
        printf 'export BUILDKITE_HOOK_EXIT_STATUS="$__bk_hook_exit"\n'
        printf 'export BUILDKITE_HOOK_WORKING_DIR="$PWD"\n'
        printf 'export -p > %q\n' "${after}"
        printf 'exit "$__bk_hook_exit"\n'
    } > "${wrapper}"
    chmod +x "${wrapper}"

    bash "${wrapper}"
    exit_code=$?

    # If the hook called a bare `exit N` itself, sourcing ends there and the lines after
    # it in the wrapper (including the after-dump) never run - the same real limitation
    # buildkite-agent's own wrapper has. Fall back to "no changes" rather than crash.
    [[ -s "${after}" ]] || cp "${before}" "${after}"

    local added
    added="$(comm -13 <(sort "${before}") <(sort "${after}") | grep -E '^declare -x ' | grep -Ev "${EXCLUDE_RE}" || true)"
    if [[ -n "${added}" ]]; then
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            # `declare -x` inside a function scopes locally - force it global with -gx so
            # the export actually reaches this script's own (and all later hooks') environment.
            eval "${line/declare -x /declare -gx }"
            echo "${line}" >> "${BASH_ENV}"
        done <<< "${added}"
    fi

    local removed
    removed="$(comm -23 <(sort "${before}") <(sort "${after}") | grep -E '^declare -x ' | grep -Ev "${EXCLUDE_RE}" || true)"
    if [[ -n "${removed}" ]]; then
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            local name
            name="$(sed -E 's/^declare -x ([A-Za-z_][A-Za-z0-9_]*)(=.*)?$/\1/' <<< "${line}")"
            if ! grep -q "^declare -x ${name}=" "${after}" && ! grep -q "^declare -x ${name}\$" "${after}"; then
                unset "${name}"
                echo "unset ${name}" >> "${BASH_ENV}"
            fi
        done <<< "${removed}"
    fi

    if [[ -n "${BUILDKITE_HOOK_WORKING_DIR:-}" ]] && [[ -d "${BUILDKITE_HOOK_WORKING_DIR}" ]]; then
        cd "${BUILDKITE_HOOK_WORKING_DIR}" || true
    fi

    rm -f "${before}" "${after}" "${wrapper}"
    return "${exit_code}"
}

GATE_EXIT=""
COMMAND_EXIT=0
POST_COMMAND_EXIT=""
PRE_ARTIFACT_EXIT=""
POST_ARTIFACT_EXIT=""
PRE_EXIT_EXIT=""

for hook in pre-checkout checkout post-checkout environment pre-command command post-command pre-artifact post-artifact pre-exit; do
    hook_listed "${hook}" || continue

    # A gate-phase (pre-command-or-earlier) failure wins immediately and skips
    # everything else - except pre-exit, which always still runs if listed.
    if [[ "${hook}" != "pre-exit" ]] && [[ -n "${GATE_EXIT}" ]]; then
        continue
    fi

    case "${hook}" in
        command)
            hook_file="${PLUGIN_ROOT}/hooks/command"
            if [[ -f "${hook_file}" ]]; then
                echo "+++ Running hooks/command"
                run_hook_file "${hook_file}"
                COMMAND_EXIT=$?
            elif [[ -n "${FALLBACK_COMMAND}" ]]; then
                echo "+++ Running command (plugin defines no command hook)"
                bash -c "${FALLBACK_COMMAND}"
                COMMAND_EXIT=$?
            fi
            ;;
        pre-exit)
            hook_file="${PLUGIN_ROOT}/hooks/pre-exit"
            if [[ -f "${hook_file}" ]]; then
                echo "+++ Running hooks/pre-exit"
                run_hook_file "${hook_file}"
                PRE_EXIT_EXIT=$?
            fi
            ;;
        pre-checkout | checkout | post-checkout | environment | pre-command)
            hook_file="${PLUGIN_ROOT}/hooks/${hook}"
            if [[ -f "${hook_file}" ]]; then
                echo "+++ Running hooks/${hook}"
                run_hook_file "${hook_file}"
                hex=$?
                [[ "${hex}" -ne 0 ]] && GATE_EXIT="${hex}"
            fi
            ;;
        post-command)
            hook_file="${PLUGIN_ROOT}/hooks/post-command"
            if [[ -f "${hook_file}" ]]; then
                echo "+++ Running hooks/post-command"
                run_hook_file "${hook_file}"
                hex=$?
                [[ "${hex}" -ne 0 ]] && POST_COMMAND_EXIT="${hex}"
            fi
            ;;
        pre-artifact)
            hook_file="${PLUGIN_ROOT}/hooks/pre-artifact"
            if [[ -f "${hook_file}" ]]; then
                echo "+++ Running hooks/pre-artifact"
                run_hook_file "${hook_file}"
                hex=$?
                [[ "${hex}" -ne 0 ]] && PRE_ARTIFACT_EXIT="${hex}"
            fi
            ;;
        post-artifact)
            hook_file="${PLUGIN_ROOT}/hooks/post-artifact"
            if [[ -f "${hook_file}" ]]; then
                echo "+++ Running hooks/post-artifact"
                run_hook_file "${hook_file}"
                hex=$?
                [[ "${hex}" -ne 0 ]] && POST_ARTIFACT_EXIT="${hex}"
            fi
            ;;
    esac
done

# Exit-code precedence, mirrored from Buildkite's own documented lifecycle
# (buildkite.com/docs/agent/lifecycle#exit-codes):
#   pre-command-or-earlier failure wins immediately (command never runs)
#   > pre-exit failure always wins last
#   > pre-artifact/post-artifact failure beats a successful command
#   > post-command failure beats the command's own exit code
#   > the command's own exit code
final_exit=0
if [[ -n "${GATE_EXIT}" ]]; then
    final_exit="${GATE_EXIT}"
elif [[ -n "${PRE_ARTIFACT_EXIT}" ]]; then
    final_exit="${PRE_ARTIFACT_EXIT}"
elif [[ -n "${POST_ARTIFACT_EXIT}" ]]; then
    final_exit="${POST_ARTIFACT_EXIT}"
elif [[ -n "${POST_COMMAND_EXIT}" ]]; then
    final_exit="${POST_COMMAND_EXIT}"
else
    final_exit="${COMMAND_EXIT}"
fi
if [[ -n "${PRE_EXIT_EXIT}" ]] && [[ "${PRE_EXIT_EXIT}" -ne 0 ]]; then
    final_exit="${PRE_EXIT_EXIT}"
fi

exit "${final_exit}"
