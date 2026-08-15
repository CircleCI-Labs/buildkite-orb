#!/bin/bash
set -uo pipefail

# Flattens a block-style YAML mapping (scalars, one-or-more-level nested mappings, and
# sequences of scalars) into BUILDKITE_PLUGIN_<NAME>_<KEY> environment variables,
# following the same flattening rules Buildkite documents and that real plugin configs
# rely on (buildkite.com/docs/pipelines/integrations/plugins), independently observed
# against real plugin.yml/README config shapes:
#   - a scalar value assigns BUILDKITE_PLUGIN_<NAME>_<KEY> directly
#   - a sequence gets _0, _1, _2, ... suffixes per item
#   - a nested mapping gets a _<SUBKEY> suffix per field (recursively)
#   - every KEY/SUBKEY is individually uppercased with hyphens/spaces -> underscores
#
# This is a deliberately small subset of YAML - block-style only, no flow-style
# ({a: b}, [a, b]), no multi-line scalars, no anchors/aliases, no inline "# comments"
# trailing a value on the same line. Every real config shown in the vault-secrets,
# aws-assume-role-with-web-identity and trivy plugin READMEs (this orb's verified
# targets) parses correctly with this subset.
#
# Buildkite also sets BUILDKITE_PLUGIN_CONFIGURATION (the whole config as one JSON
# string) - this orb does not reconstruct that value. See the README.

RAW_CONFIG="${ORB_VAL_CONFIG}"

if [[ -z "${RAW_CONFIG}" ]]; then
    echo "configure: no config provided - nothing to flatten."
    exit 0
fi

if [[ -z "${BUILDKITE_PLUGIN_ENV_PREFIX:-}" ]]; then
    echo "configure: \$BUILDKITE_PLUGIN_ENV_PREFIX is not set. Run the fetch-plugin command/step before configure." >&2
    exit 1
fi

if command -v circleci > /dev/null 2>&1; then
    RAW_CONFIG="$(circleci env subst <<< "${RAW_CONFIG}")"
else
    echo "configure: 'circleci' CLI not found on PATH - using config as-is, without \$VAR substitution." >&2
fi

format_env_key() {
    # Uppercase, then turn ANY character outside [A-Za-z0-9_] into an underscore - not
    # just hyphens/spaces. A bare `export NAME=value` requires NAME to be a legal bash
    # identifier; real buildkite-agent (a Go program) has no such restriction and would
    # happily set an env var literally named e.g. BUILDKITE_PLUGIN_X_DOCKER.HOST, but
    # this orb's `export "${name}=${value}"` would hard-fail on that name (see the
    # README's Config flattening section for this documented divergence). Collapsing the
    # full punctuation class, not just hyphen/space, keeps every derived name a legal
    # bash identifier so `export` can never fail here.
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9_]/_/g'
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

export_leaf() {
    # export_leaf PREFIX RAW_VALUE
    local name="$1" value quoted
    value="$(strip_quotes "$2")"
    if [[ "${value}" == "{"* || "${value}" == "["* ]]; then
        echo "configure: WARNING: ${name} looks like flow-style YAML ('${value}') - this orb's config flattening only supports block-style YAML (see the README's 'Config flattening' section) and will export this value as one opaque, unparsed string rather than flattening it further. Rewrite this key as block-style if the plugin's hook expects it flattened." >&2
    fi
    printf -v quoted '%q' "${value}"
    echo "export ${name}=${quoted}" >> "${BASH_ENV}"
    export "${name}=${value}"
    echo "  ${name}=${value}"
}

# --- Tokenize into (indent, content) pairs, dropping blank lines and comments. ---
declare -a LINE_INDENT=()
declare -a LINE_CONTENT=()

while IFS= read -r raw_line; do
    raw_line="${raw_line%$'\r'}"
    [[ "${raw_line}" == "---" ]] && continue
    trimmed="${raw_line#"${raw_line%%[![:space:]]*}"}"
    [[ -z "${trimmed}" ]] && continue
    [[ "${trimmed:0:1}" == "#" ]] && continue
    indent=$((${#raw_line} - ${#trimmed}))
    LINE_INDENT+=("${indent}")
    LINE_CONTENT+=("${trimmed}")
done <<< "${RAW_CONFIG}"

TOTAL=${#LINE_CONTENT[@]}

echo "Flattening config onto ${BUILDKITE_PLUGIN_ENV_PREFIX}_*:"

declare -a STACK_INDENT=(-1)
declare -a STACK_PREFIX=("${BUILDKITE_PLUGIN_ENV_PREFIX}")
declare -A ARR_IDX=()

for ((i = 0; i < TOTAL; i++)); do
    indent="${LINE_INDENT[$i]}"
    content="${LINE_CONTENT[$i]}"

    while ((${#STACK_INDENT[@]} > 1)) && ((indent <= STACK_INDENT[-1])); do
        unset 'STACK_INDENT[-1]'
        unset 'STACK_PREFIX[-1]'
    done
    parent_prefix="${STACK_PREFIX[-1]}"

    if [[ "${content}" == "-"* ]]; then
        idx="${ARR_IDX[${parent_prefix}]:-0}"
        item_prefix="${parent_prefix}_${idx}"
        ARR_IDX[${parent_prefix}]=$((idx + 1))

        item_rest="${content#-}"
        item_rest="${item_rest#"${item_rest%%[![:space:]]*}"}"

        if [[ -z "${item_rest}" ]]; then
            # "- " alone: the item's own fields follow on more-indented lines.
            STACK_INDENT+=("${indent}")
            STACK_PREFIX+=("${item_prefix}")
        elif [[ "${item_rest}" == *": "* || "${item_rest}" == *: ]]; then
            # "- key: value" - first field of a mapping-shaped sequence item.
            key="${item_rest%%:*}"
            value="${item_rest#*:}"
            value="${value#"${value%%[![:space:]]*}"}"
            field_prefix="${item_prefix}_$(format_env_key "${key}")"
            [[ -n "${value}" ]] && export_leaf "${field_prefix}" "${value}"
            STACK_INDENT+=("${indent}")
            STACK_PREFIX+=("${item_prefix}")
        else
            # "- value" - a plain scalar sequence item.
            export_leaf "${item_prefix}" "${item_rest}"
        fi
        continue
    fi

    key="${content%%:*}"
    value="${content#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    entry_prefix="${parent_prefix}_$(format_env_key "${key}")"

    if [[ -n "${value}" ]]; then
        export_leaf "${entry_prefix}" "${value}"
        continue
    fi

    # Empty value: this opens a nested mapping/sequence only if the next line is
    # indented further; otherwise it's a genuinely empty scalar.
    next_indent=-1
    if ((i + 1 < TOTAL)); then
        next_indent="${LINE_INDENT[$((i + 1))]}"
    fi

    if ((next_indent > indent)); then
        STACK_INDENT+=("${indent}")
        STACK_PREFIX+=("${entry_prefix}")
    else
        export_leaf "${entry_prefix}" ""
    fi
done
