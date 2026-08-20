# Migrating from Buildkite

## Mapping your existing config

Here's a real Buildkite pipeline step using a plugin, next to this orb's equivalent:

```yaml
# pipeline.yml (Buildkite)
steps:
  - label: ":mag: Scan for vulnerabilities"
    command: "echo 'scanning repository'"
    plugins:
      - equinixmetal-buildkite/trivy#v1.22.0:
          severity: "CRITICAL,HIGH"
```

```yaml
# .circleci/config.yml (this orb)
version: 2.1
orbs:
  buildkite: cci-labs/buildkite@x.y.z
workflows:
  main:
    jobs:
      - buildkite/plugin:
          plugin: "equinixmetal-buildkite/trivy#v1.22.0"
          config: |
            severity: "CRITICAL,HIGH"
          command: "echo 'scanning repository'"
```

What actually changed, concept by concept:

- **A Buildkite step's `plugins:` entry becomes a `buildkite/plugin` command (inline, among
  native steps) or job (standalone).** The plugin reference (`org/name#ref`) maps straight onto
  this orb's `plugin` parameter, unchanged; `fetch-plugin` resolves it exactly the way real
  Buildkite agents do (see [How it works](ARCHITECTURE.md#how-it-works)).
- **The plugin's config block (nested under the plugin's key in real Buildkite) becomes this
  orb's `config:` parameter**, the same YAML shape, just without the plugin-name key wrapping
  it, since this orb already knows which plugin it's for from `plugin:`. `configure` flattens it
  into `BUILDKITE_PLUGIN_<NAME>_<KEY>` the same way Buildkite's own agent would (see
  [Config flattening](ARCHITECTURE.md#config-flattening)).
- **The step's own `command:`** maps directly onto this orb's `command` parameter; it only
  actually runs if the plugin defines no `hooks/command` of its own, exactly matching real
  Buildkite's precedence (see [Hooks and their CircleCI-native equivalents](ARCHITECTURE.md#hooks-and-their-circleci-native-equivalents)).
- **Where the vendor's env vars come from doesn't change on this axis** the way it does for the
  hosted-account bridges: real Buildkite also expects most secrets as plain agent/pipeline
  environment variables, so `$MY_SECRET`-style references work the same way here, resolved via
  `circleci env subst` instead of Buildkite's own agent environment hooks. See the
  [environment mapping](ARCHITECTURE.md#circle_-to-buildkite_-environment-mapping) for the values
  only Buildkite's control plane can produce (`BUILDKITE_AGENT_ACCESS_TOKEN`, and similar) that
  have no equivalent here at all.
- **What Buildkite's control plane does for you that CircleCI does natively instead:** the
  `buildkite-agent artifact upload`/`meta-data`/`env` calls a hook makes are answered by this
  orb's own local shim (see [`buildkite-agent` subcommands](ARCHITECTURE.md#buildkite-agent-subcommands))
  rather than a real agent talking to `agent.buildkite.com`. `store_artifacts` on the shim's
  `artifact-dir` is the direct CircleCI-native equivalent of an uploaded Buildkite artifact.
