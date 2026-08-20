# Commands and Job Reference

| Name | Kind | What it does |
|---|---|---|
| `plugin` | command, job | The aggregate most users want: fetch-plugin -> map-env -> install-agent-shim -> configure -> run-hooks, in order. |
| `fetch-plugin` | command | Resolves the plugin reference and git-clones it at the pinned ref, cached. |
| `map-env` | command | Exports the CIRCLE_*->BUILDKITE_* mapping into `$BASH_ENV`. |
| `install-agent-shim` | command | Puts a `buildkite-agent` reimplementation on `$PATH`. |
| `configure` | command | Flattens `config:` onto `BUILDKITE_PLUGIN_<NAME>_<KEY>` variables. |
| `run-hooks` | command | Runs the plugin's `hooks/*` files in Buildkite's fixed lifecycle order, with env-diff threading. |

**Reach for the granular commands instead of the `plugin` aggregate when:** you're chaining
multiple plugins in one job (give each `fetch-plugin` call its own `plugin-dir`; see
[`src/examples/chain_two_plugins.yml`](../src/examples/chain_two_plugins.yml)), or you need native
steps interleaved between individual stages, e.g. inspecting the flattened
`BUILDKITE_PLUGIN_*` vars after `configure` but before `run-hooks` executes the hooks.

## Layering and future multi-plugin chaining

Each command does one job and reads/writes plain environment variables and `$BASH_ENV`, with
nothing baked into a single monolithic script. Calling `fetch-plugin` -> `configure` -> `run-hooks`
more than once in the same job (with a different `plugin-dir` each time to avoid colliding clones)
approximates chaining several plugins' hooks today. See [`docs/ROADMAP.md`](ROADMAP.md)'s
"Command-split decisions" for the full mechanism and item 3 for why a more formal chaining command
isn't built yet.

## `plugin` (command and job) parameters

| Parameter | Type | Default | What it does |
|---|---|---|---|
| `executor` *(job only)* | executor | `docker` | `buildkite/docker` (plain bash hooks), `buildkite/machine` (hooks shell out to Docker), or `buildkite/docker-toolchains` (hooks need a real toolchain on `PATH`). |
| `checkout` *(job only)* | boolean | `true` | Run native CircleCI checkout before the plugin's hooks. |
| `plugin` | string | *(required)* | The plugin reference (`name#ref`, `org/name#ref`, or a full git URL, optionally with a subdirectory). |
| `config` | string | `""` | The plugin's configuration as YAML, exactly as under a plugin's key in `pipeline.yml`. `$SECRET` resolved via `circleci env subst`. |
| `command` | string | `""` | Shell command run when the plugin defines no `hooks/command` of its own. |
| `hooks` | string | `environment,pre-checkout,post-checkout,pre-command,command,post-command,pre-exit` | Comma-separated filter of which hook names run; a filter, not a sequence, always executed in Buildkite's fixed order. |
| `label` | string | `Running Buildkite plugin hooks` | Step name for the hooks-running step; override when chaining plugins so job-log steps are distinguishable. |
| `map-env` | boolean | `true` | Run the `map-env` command before hooks. |
| `extra-env` | string | `""` | Extra `KEY=VALUE` pairs applied after the base `map-env` mapping. |
| `install-shim` | boolean | `true` | Run `install-agent-shim` before hooks. |
| `shim-dir` | string | `/tmp/buildkite-agent-shim` | Directory the shim script is written to and prepended onto `PATH`. |
| `artifact-dir` | string | `/tmp/buildkite-artifacts` | Directory `buildkite-agent artifact upload` copies matched files into. |
| `meta-data-dir` | string | `/tmp/buildkite-meta-data` | Directory backing `buildkite-agent meta-data get/set`, this-job-only scope. |
| `store-artifacts` *(job only)* | boolean | `true` | Auto-`store_artifacts` whatever hooks uploaded via the shim, from `artifact-dir`. |
| `plugin-dir` | string | `/tmp/buildkite-plugin` | Directory the plugin's repo is cloned into. |
| `plugin-cache` | boolean | `true` | Cache the cloned plugin repo, keyed on the plugin reference string. Only ever reused for a pinned (`#tag`/`#sha`) reference; an unpinned reference always re-clones fresh. See [Limits](LIMITS.md). |
| `always-clone-fresh` | boolean | `false` | Force a fresh clone even if a cache/prior clone exists (mirrors Buildkite's `BUILDKITE_PLUGINS_ALWAYS_CLONE_FRESH`). |
| `working-directory` | string | `.` | Directory hooks start running from (Buildkite's `BUILDKITE_BUILD_CHECKOUT_PATH` equivalent). |
| `cache-key-prefix` | string | `v1` | Prefix applied to every cache key this orb writes. |
| `test-results-path` | string | `""` | Opt-in only. When set, runs `store_test_results` against this path after the hooks finish. Left empty (the default), nothing runs; there's no vendor-wide default path to fall back to. |

Individual commands (`fetch-plugin`, `map-env`, `install-agent-shim`, `configure`, `run-hooks`)
expose the matching subset of these parameters under the same names. See each command's own
description on the [Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/buildkite)
for the exhaustive, always-current list.

## Worked example: composing the granular commands by hand

```yaml
version: 2.1
orbs:
  buildkite: cci-labs/buildkite@x.y.z
jobs:
  scan:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - buildkite/fetch-plugin:
          plugin: "equinixmetal-buildkite/trivy#v1.22.0"
      - buildkite/map-env
      - buildkite/install-agent-shim
      - buildkite/configure:
          config: |
            severity: "CRITICAL,HIGH"
      - buildkite/run-hooks:
          command: "echo 'scanning repository'"
      - store_artifacts:
          path: /tmp/buildkite-artifacts
workflows:
  main:
    jobs:
      - scan
```
