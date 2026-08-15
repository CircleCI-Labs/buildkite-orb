#!/bin/bash
set -uo pipefail
# Deliberately no `-e` in this script's own `set` above - but that is NOT enough on
# CircleCI: the default `run:` step shell is `/bin/bash -eo pipefail`, so `-e` is
# already active before this script's own `set` line even runs, and `set -uo pipefail`
# only ADDS `-u`/`pipefail` - it cannot cancel an `-e` that's already on. Without the
# explicit `set +e` below, the very first hook (or the fallback `command:`) that exits
# non-zero would abort this whole script immediately: `hex=$?` would never run, the
# GATE_EXIT/POST_COMMAND_EXIT/etc. bookkeeping would never happen, and pre-exit -
# documented below as always running - would never run either. `set +e` explicitly
# cancels the inherited `-e` so this script actually gets the "keep running past a
# failing hook" behaviour its design (and buildkite-agent's own lifecycle) requires.
set +e

PLUGIN_ROOT="${BUILDKITE_PLUGIN_ROOT:-}"
FALLBACK_COMMAND="${ORB_VAL_COMMAND}"
WORKDIR="${ORB_VAL_WORKING_DIRECTORY}"

# BUILDKITE_COMMAND requires no control plane - it's just the command string for this
# job - so unlike BUILDKITE_AGENT_ACCESS_TOKEN/BUILDKITE_AGENT_ENDPOINT there's no reason
# to leave it unset. Set even when a plugin's own hooks/command overrides the fallback,
# matching Buildkite's own semantics (BUILDKITE_COMMAND is the step's configured command,
# not "whichever command hook actually ran").
export BUILDKITE_COMMAND="${FALLBACK_COMMAND}"
printf 'export BUILDKITE_COMMAND=%q\n' "${FALLBACK_COMMAND}" >> "${BASH_ENV}"

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
# PWD/OLDPWD are handled explicitly via the pwd_file side channel in run_hook_file
# instead (matching Buildkite's own documented behaviour: a hook that cd's persists
# that cd to the next hook and to the command), and re-exporting them as plain values
# would fight with bash's own automatic PWD/OLDPWD management.
EXCLUDE_RE='^declare -[a-zA-Z]*x[a-zA-Z]* (PWD|OLDPWD|_|SHLVL|BASH_ENV)='

# run_hook_file HOOK_PATH
# Runs the hook in its own bash process, dumping the exported-variable set before and
# after (via `export -p`, which - unlike plain `env` - correctly quotes multi-line and
# special-character values). Diffs the two dumps and applies the diff to *this* shell
# and to $BASH_ENV, then follows the hook's own final working directory. Returns the
# hook process's exit status.
#
# The hook's final $PWD is threaded back through a SEPARATE one-line file, not through
# the general export -p diff: the wrapper's own bookkeeping (the hook's exit status,
# its final $PWD) is internal to this function, not a real Buildkite variable and not
# something the hook itself set - if it were exported and picked up by the general
# added/removed diff machinery below, it would get written into $BASH_ENV and leak into
# every later native CircleCI step's environment (and, worse, every later hook's
# process, re-threaded and overwritten hook after hook). The exit status doesn't need a
# side channel at all: the wrapper's own `exit "$__bk_hook_exit"` already makes it
# `bash`'s own process exit code, captured below by plain `$?`.
run_hook_file() {
    local hook_path="$1"
    local before after wrapper pwd_file exit_code

    before="$(mktemp)"
    after="$(mktemp)"
    wrapper="$(mktemp)"
    pwd_file="$(mktemp)"

    # These printf format strings are the CONTENTS of the wrapper script we're
    # generating, not commands to run now - $__bk_hook_exit/pwd are deliberately left
    # unexpanded here so they're evaluated later, inside the wrapper, after the hook runs.
    # shellcheck disable=SC2016
    {
        printf '#!/bin/bash\n'
        printf 'export -p > %q\n' "${before}"
        printf '. %q\n' "${hook_path}"
        printf '__bk_hook_exit=$?\n'
        printf 'pwd > %q\n' "${pwd_file}"
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

    # `export -p` renders any exported variable with an extra attribute differently from
    # a plain export - e.g. `declare -ix NAME=...` (integer), `declare -ax NAME=(...)`
    # (array), `declare -rx NAME=...` (readonly) - never as the literal string
    # `declare -x `. Anchoring on that literal string would miss any such variable
    # entirely (a new attributed export never threads forward) and would misfire on the
    # *removed* side for a variable that was already exported and merely got re-declared
    # with an attribute (its plain `declare -x NAME=...` line vanishes from the "after"
    # dump, replaced by e.g. `declare -ix NAME=...`, which looks like a removal even
    # though the variable is still very much present). Match any attribute combination
    # that contains an `x` anywhere in it, in any order, instead.
    local added
    added="$(comm -13 <(sort "${before}") <(sort "${after}") | grep -E '^declare -[a-zA-Z]*x[a-zA-Z]* ' | grep -Ev "${EXCLUDE_RE}" || true)"
    if [[ -n "${added}" ]]; then
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            # `declare -x` inside a function scopes locally - force it global with -gx so
            # the export actually reaches this script's own (and all later hooks') environment.
            eval "${line/declare -/declare -g}"
            echo "${line}" >> "${BASH_ENV}"
        done <<< "${added}"
    fi

    local removed
    removed="$(comm -23 <(sort "${before}") <(sort "${after}") | grep -E '^declare -[a-zA-Z]*x[a-zA-Z]* ' | grep -Ev "${EXCLUDE_RE}" || true)"
    if [[ -n "${removed}" ]]; then
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            local name
            name="$(sed -E 's/^declare -[a-zA-Z]*x[a-zA-Z]* ([A-Za-z_][A-Za-z0-9_]*)(=.*)?$/\1/' <<< "${line}")"
            if ! grep -Eq "^declare -[a-zA-Z]*x[a-zA-Z]* ${name}=" "${after}" && ! grep -Eq "^declare -[a-zA-Z]*x[a-zA-Z]* ${name}\$" "${after}"; then
                unset "${name}"
                echo "unset ${name}" >> "${BASH_ENV}"
            fi
        done <<< "${removed}"
    fi

    # If the hook called a bare `exit N` before reaching the `pwd > ...` line, pwd_file
    # is left empty - fall back to staying in the current directory rather than cd-ing
    # into garbage.
    if [[ -s "${pwd_file}" ]]; then
        local hook_pwd
        hook_pwd="$(cat "${pwd_file}")"
        if [[ -d "${hook_pwd}" ]]; then
            cd "${hook_pwd}" || true
        fi
    fi

    rm -f "${before}" "${after}" "${wrapper}" "${pwd_file}"
    return "${exit_code}"
}

GATE_EXIT=""
COMMAND_EXIT=0
POST_COMMAND_EXIT=""
PRE_ARTIFACT_EXIT=""
POST_ARTIFACT_EXIT=""
PRE_EXIT_EXIT=""

for hook in environment pre-checkout checkout post-checkout pre-command command post-command pre-artifact post-artifact pre-exit; do
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
        environment | pre-checkout | checkout | post-checkout | pre-command)
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
