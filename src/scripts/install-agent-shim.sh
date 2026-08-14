#!/bin/bash
set -euo pipefail

SHIM_DIR="${ORB_VAL_SHIM_DIR}"
ARTIFACT_DIR="${ORB_VAL_ARTIFACT_DIR}"
META_DATA_DIR="${ORB_VAL_META_DATA_DIR}"

mkdir -p "${SHIM_DIR}" "${ARTIFACT_DIR}" "${META_DATA_DIR}"

# The shim is written as its own standalone script (not sourced from this one) because
# it needs to run as `buildkite-agent <subcommand>` from arbitrary hook processes later
# in the job, long after this install step has finished.
cat > "${SHIM_DIR}/buildkite-agent" <<'SHIM_EOF'
#!/bin/bash
# buildkite-agent shim, installed by the cci-labs/buildkite orb's install-agent-shim
# command. This is NOT the real buildkite-agent binary - it is a small reimplementation
# of the subset of its CLI surface that can be given faithful, non-lossy behaviour
# without a real Buildkite account or control plane. See the orb's README for the full
# "shimmed vs unsupported" table and the reasoning behind each entry.
set -uo pipefail

ARTIFACT_DIR="${BUILDKITE_SHIM_ARTIFACT_DIR:-/tmp/buildkite-artifacts}"
META_DATA_DIR="${BUILDKITE_SHIM_META_DATA_DIR:-/tmp/buildkite-meta-data}"

unsupported() {
  local subcommand="$1" reason="$2"
  echo "buildkite-agent: '${subcommand}' is not supported by the cci-labs/buildkite orb's shim." >&2
  echo "  ${reason}" >&2
  echo "  See the 'buildkite-agent subcommands' table in the orb's README for the full list." >&2
  exit 1
}

cmd_meta_data() {
  local action="${1:-}"; shift || true
  mkdir -p "${META_DATA_DIR}"
  case "${action}" in
    set)
      local key="${1:-}" value="${2:-}"
      if [[ -z "${key}" ]]; then
        echo "buildkite-agent meta-data set: a key is required" >&2
        exit 1
      fi
      printf '%s' "${value}" > "${META_DATA_DIR}/${key}"
      ;;
    get)
      local key="${1:-}" default="" have_default=false
      shift || true
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --default) default="${2:-}"; have_default=true; shift 2 ;;
          *) shift ;;
        esac
      done
      if [[ -f "${META_DATA_DIR}/${key}" ]]; then
        cat "${META_DATA_DIR}/${key}"
      elif ${have_default}; then
        printf '%s' "${default}"
      else
        echo "buildkite-agent meta-data get: key '${key}' does not exist" >&2
        exit 1
      fi
      ;;
    exists)
      local key="${1:-}"
      [[ -f "${META_DATA_DIR}/${key}" ]]
      exit $?
      ;;
    keys)
      ( cd "${META_DATA_DIR}" 2>/dev/null && ls -1 ) || true
      ;;
    *)
      unsupported "meta-data ${action}" "only 'set', 'get', 'exists' and 'keys' are implemented, scoped to this CircleCI job only - see the README, this does not span multiple CircleCI jobs the way Buildkite's build-wide meta-data store does."
      ;;
  esac
}

cmd_artifact() {
  local action="${1:-}"; shift || true
  mkdir -p "${ARTIFACT_DIR}"
  case "${action}" in
    upload)
      local glob="${1:-}"
      if [[ -z "${glob}" ]]; then
        echo "buildkite-agent artifact upload: a glob is required" >&2
        exit 1
      fi
      shopt -s globstar nullglob
      local matched=false f
      for f in ${glob}; do
        [[ -f "${f}" ]] || continue
        matched=true
        mkdir -p "${ARTIFACT_DIR}/$(dirname -- "${f}")"
        cp -p "${f}" "${ARTIFACT_DIR}/${f}"
        echo "buildkite-agent artifact upload: copied ${f} -> ${ARTIFACT_DIR}/${f}"
      done
      shopt -u globstar nullglob
      if ! ${matched}; then
        echo "buildkite-agent artifact upload: no files matched '${glob}'" >&2
        exit 1
      fi
      echo "buildkite-agent artifact upload: files staged under ${ARTIFACT_DIR} - add a store_artifacts step for that path to actually persist them on CircleCI (the 'plugin' job does this automatically)."
      ;;
    download)
      local glob="${1:-}" dest="${2:-.}"
      if [[ -z "${glob}" ]]; then
        echo "buildkite-agent artifact download: a glob is required" >&2
        exit 1
      fi
      mkdir -p "${dest}"
      shopt -s globstar nullglob
      local matched=false f rel
      for f in "${ARTIFACT_DIR}"/${glob}; do
        [[ -f "${f}" ]] || continue
        matched=true
        rel="${f#"${ARTIFACT_DIR}"/}"
        mkdir -p "${dest}/$(dirname -- "${rel}")"
        cp -p "${f}" "${dest}/${rel}"
        echo "buildkite-agent artifact download: copied ${f} -> ${dest}/${rel}"
      done
      shopt -u globstar nullglob
      if ! ${matched}; then
        echo "buildkite-agent artifact download: no artifacts under ${ARTIFACT_DIR} matched '${glob}'. This shim can only see artifacts uploaded earlier in THIS job - fetching artifacts uploaded by a different job needs attach_workspace/persist_to_workspace wiring of your own." >&2
        exit 1
      fi
      ;;
    *)
      unsupported "artifact ${action}" "only 'upload' and 'download' are implemented, against a local directory rather than Buildkite's real artifact store."
      ;;
  esac
}

cmd_env() {
  local action="${1:-}"; shift || true
  case "${action}" in
    dump)
      env
      ;;
    get)
      local key="${1:-}"
      if [[ -n "${!key:-}" ]]; then
        printf '%s' "${!key}"
      else
        exit 1
      fi
      ;;
    set)
      # A child process can't mutate its parent hook's shell environment, so this only
      # works if the caller does `eval "$(buildkite-agent env set ...)"`.
      local pair="${1:-}"
      if [[ -z "${pair}" || "${pair}" != *"="* ]]; then
        echo "buildkite-agent env set: expected NAME=VALUE" >&2
        exit 1
      fi
      printf 'export %s=%q\n' "${pair%%=*}" "${pair#*=}"
      echo "buildkite-agent env set: printed an export statement to stdout - eval it (e.g. eval \"\$(buildkite-agent env set ...)\") to apply it to your current shell; this shim cannot reach into the calling hook's process on its own." >&2
      ;;
    *)
      unsupported "env ${action}" "only 'dump', 'get' and 'set' are implemented."
      ;;
  esac
}

cmd_workdir() {
  if [[ $# -eq 0 ]]; then
    pwd
  else
    unsupported "workdir ${1}" "this shim runs as its own process and cannot change the calling hook's working directory; only the no-argument form (print the current directory) is implemented."
  fi
}

main() {
  local subcommand="${1:-}"
  [[ $# -gt 0 ]] && shift || true

  case "${subcommand}" in
    "" )
      echo "buildkite-agent (cci-labs/buildkite orb shim) - see the orb's README for the full shimmed/unsupported subcommand table."
      ;;
    --version|-v|--help|-h)
      echo "buildkite-agent-shim (cci-labs/buildkite orb) - not the real buildkite-agent"
      ;;
    artifact) cmd_artifact "$@" ;;
    meta-data) cmd_meta_data "$@" ;;
    env) cmd_env "$@" ;;
    workdir) cmd_workdir "$@" ;;
    annotate|annotation)
      unsupported "${subcommand}" "Buildkite annotations render onto the Buildkite build page UI, which has no CircleCI equivalent. Have the hook write to a file and store_artifacts it instead."
      ;;
    pipeline)
      unsupported "pipeline ${1:-}" "pipeline upload mutates the running build's step graph mid-job; CircleCI's nearest analog (the continuation orb) only runs before a workflow's jobs are scheduled, from a separate setup job, and cannot be invoked mid-job."
      ;;
    step)
      unsupported "step ${1:-}" "reading or mutating other steps in the same build has no CircleCI primitive - there is no way to reach 'other jobs in this workflow' imperatively from inside a running job."
      ;;
    oidc)
      unsupported "oidc" "this issues a Buildkite-signed OIDC token from agent.buildkite.com; it cannot be reimplemented against a Buildkite identity that doesn't exist. Use CircleCI's own OIDC tokens instead (circleci.com/docs/openid-connect-tokens) and reconfigure the plugin's trust policy to match - this is plugin-specific rework, not a generic shim."
      ;;
    secret)
      unsupported "secret" "this fetches from Buildkite Pipelines Secrets, which has no CircleCI equivalent. Use a CircleCI context or project environment variable instead and reference it directly."
      ;;
    lock)
      unsupported "lock" "this coordinates across concurrent agents on the same self-hosted host; CircleCI jobs don't share a host this way. Use CircleCI's own concurrency controls at the workflow level instead."
      ;;
    redactor)
      unsupported "redactor" "this registers values for the real agent's live log-streaming filter to scrub; there is no equivalent hook into CircleCI's log pipeline, and silently no-opping it would risk leaking a secret the hook believed was being redacted."
      ;;
    pause|resume|stop|build|job)
      unsupported "${subcommand}" "this controls the agent process or the wider build/job remotely via Buildkite's control plane, which doesn't exist here. Use CircleCI's own API/UI to control the job instead."
      ;;
    *)
      unsupported "${subcommand}" "this subcommand is not implemented by this shim."
      ;;
  esac
}

main "$@"
SHIM_EOF

chmod +x "${SHIM_DIR}/buildkite-agent"

{
  echo "export PATH=\"${SHIM_DIR}:\${PATH}\""
  echo "export BUILDKITE_SHIM_ARTIFACT_DIR='${ARTIFACT_DIR}'"
  echo "export BUILDKITE_SHIM_META_DATA_DIR='${META_DATA_DIR}'"
} >> "${BASH_ENV}"

export PATH="${SHIM_DIR}:${PATH}"
export BUILDKITE_SHIM_ARTIFACT_DIR="${ARTIFACT_DIR}"
export BUILDKITE_SHIM_META_DATA_DIR="${META_DATA_DIR}"

echo "Installed buildkite-agent shim at ${SHIM_DIR}/buildkite-agent"
