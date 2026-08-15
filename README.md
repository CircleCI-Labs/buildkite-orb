# Buildkite Orb (Unofficial) [![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/buildkite-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/buildkite-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/buildkite.svg)](https://circleci.com/developer/orbs/orb/cci-labs/buildkite) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/buildkite-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

Run **one [Buildkite plugin](https://buildkite.com/docs/pipelines/integrations/plugins)** as a single step inside an otherwise-native CircleCI job or workflow - no Buildkite account, agent, or control plane involved. This orb resolves a plugin's git reference, clones it, flattens your config into the exact `BUILDKITE_PLUGIN_*` environment variables Buildkite itself would set, and runs the plugin's own hook scripts in Buildkite's documented order, threading environment changes forward between hooks the same way `buildkite-agent` does.

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ✅ Used by real CircleCI customers
-   ❌ **not** officially supported by CircleCI support

---

## What this is (and isn't)

This orb runs **one plugin per step**, faithfully - it is not a Buildkite pipeline
emulator. It doesn't understand `pipeline.yml`, doesn't chain multiple plugins'
`command` hooks together the way a Buildkite step with a `plugins:` array does, and
doesn't touch Buildkite's control plane in any way (there's no account to touch - this
orb never contacts `agent.buildkite.com`). What it gives you:

- **Migration parity** - a step that already works as a Buildkite plugin can run,
  largely unmodified, on CircleCI while you migrate the rest of the pipeline.
- **Access to vendor integrations that only exist as Buildkite plugins** - some
  integrations (type-aware Vault secret routing, for example) don't have an
  equivalent, comparably-deep, official CircleCI orb today.

If you need several plugins chained together the way Buildkite's `plugins:` array
does, call this orb's commands more than once in the same job - see
["Layering and future multi-plugin chaining"](#layering-and-future-multi-plugin-chaining)
below.

## Quick start

```yaml
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

That's the whole thing: fetch the plugin, flatten the config, run its hooks. See
[`src/examples/`](src/examples/) for more, including inline (command) usage and
executor overrides.

## How it works

1. **`fetch-plugin`** resolves your plugin reference the same way Buildkite does -
   `name#ref` (the `buildkite-plugins` GitHub org), `org/name#ref`, or a full
   `https://`/`ssh://`/`file://` git URL, optionally with an in-repo subdirectory - and
   git-clones it at the pinned ref, cached. It also warns (non-fatally) if the cloned
   plugin.yml's `requirements:` list names a command missing from `$PATH` - real
   Buildkite agents never install these either, so a missing one is a host-setup gap
   either way; better to see that up front than as a mysterious failure inside a hook.
2. **`map-env`** exports CircleCI's own job-context variables under their documented
   Buildkite names (`BUILDKITE_BRANCH`, `BUILDKITE_COMMIT`, ...) - see the
   [mapping table](#circle_-buildkite_-environment-mapping) below.
3. **`configure`** flattens your `config:` YAML onto `BUILDKITE_PLUGIN_<NAME>_<KEY>`
   variables following Buildkite's own documented config-flattening convention
   (independently verified against real plugin configs and hooks - see
   [Config flattening](#config-flattening)), after passing it through
   `circleci env subst` so you can reference `$MY_SECRET` without the value ever
   appearing in your CircleCI config.
4. **`install-agent-shim`** puts a `buildkite-agent` shim on `$PATH`, since plugin
   hooks unconditionally shell out to it - see the
   [subcommand table](#buildkite-agent-subcommands) below.
5. **`run-hooks`** runs the plugin's `hooks/*` files, each as its **own process**, in
   Buildkite's documented lifecycle order - see
   [Hooks and their CircleCI-native equivalents](#hooks-and-their-circleci-native-equivalents).
   This is the part that's easy to get subtly wrong: `buildkite-agent` doesn't source
   every hook into one long-lived shell - it runs each hook in its own process, diffs
   the environment before and after, and threads *only that diff* (added, changed, and
   removed variables, plus the hook's final working directory) into the next hook and
   the command. This orb reimplements that diff-and-thread mechanism exactly, rather
   than taking the simpler (but subtly wrong for many real plugins) shortcut of
   sourcing every hook into one shell. The final accumulated diff is exported into
   `$BASH_ENV`, so native CircleCI steps after this one see it too.
6. **`plugin`** is the aggregate of all four - the one most users call directly, as
   either a command (inline among native steps) or a job (`buildkite/plugin`, callable
   from a workflow, with CircleCI's own native `pre-steps`/`post-steps` available for
   interleaving - see below - and an automatic `store_artifacts` for whatever the hooks
   staged via `buildkite-agent artifact upload`).

## `CIRCLE_*` → `BUILDKITE_*` environment mapping

Set by `map-env` (and by `plugin`/the `plugin` job, which call it by default - set
`map-env: false` to skip it).

| Buildkite variable | Set from | Notes |
|---|---|---|
| `BUILDKITE` | (constant) | Always `"true"`. |
| `BUILDKITE_AGENT_NAME` | (constant) | Always `"circleci"`. |
| `BUILDKITE_PIPELINE_PROVIDER` | `CIRCLE_REPOSITORY_URL` | Guessed from the URL's host (`github`/`bitbucket`/`gitlab`/`unknown`). |
| `BUILDKITE_BUILD_CHECKOUT_PATH` | `CIRCLE_WORKING_DIRECTORY` | Falls back to `pwd`. |
| `BUILDKITE_BRANCH` | `CIRCLE_BRANCH` | |
| `BUILDKITE_COMMIT` | `CIRCLE_SHA1` | |
| `BUILDKITE_TAG` | `CIRCLE_TAG` | |
| `BUILDKITE_PULL_REQUEST` | `CIRCLE_PULL_REQUEST` | The PR number, or the string `"false"` if this isn't a PR build - matches Buildkite's own documented value exactly. |
| `BUILDKITE_ORGANIZATION_SLUG` | `CIRCLE_PROJECT_USERNAME` | |
| `BUILDKITE_PIPELINE_SLUG` | `CIRCLE_PROJECT_REPONAME` | |
| `BUILDKITE_BUILD_NUMBER` | `CIRCLE_BUILD_NUM` | |
| `BUILDKITE_BUILD_ID` | `CIRCLE_WORKFLOW_ID` | |
| `BUILDKITE_JOB_ID` | `CIRCLE_WORKFLOW_JOB_ID` | |
| `BUILDKITE_REPO` | `CIRCLE_REPOSITORY_URL` | |
| `BUILDKITE_BUILD_URL` | `CIRCLE_BUILD_URL` | |

**Deliberately left unset - no CircleCI equivalent exists:** `BUILDKITE_AGENT_ACCESS_TOKEN`
and `BUILDKITE_AGENT_ENDPOINT` are a real, per-job bearer token and API endpoint issued
by Buildkite's control plane; there is no CircleCI concept that produces an equivalent,
because there is no Buildkite account in this picture at all. A plugin that requires
either of these (rather than one of the `buildkite-agent` subcommands the shim covers)
will not work here.

Add or override entries with `extra-env` (one `KEY=VALUE` per line, applied after the
base mapping, also passed through `circleci env subst`).

## Config flattening

`configure` reimplements Buildkite's own documented config-flattening convention
(independently verified against real plugin configs and the hooks that read them -
see the [Verified targets](#verified-targets) section), against a deliberately small
subset of block-style YAML - scalars, sequences (including sequences of scalars AND
sequences of mappings, e.g. a list of `- key: value` items, each flattened the same
way a nested mapping would be), and (arbitrarily nested) mappings. No flow-style
(`{a: b}`), multi-line scalars, anchors/aliases, or same-line trailing `#` comments.
Every real config in the vault-secrets, aws-assume-role-with-web-identity and trivy
plugins' own READMEs (this orb's verified targets) parses correctly with this subset -
see [`src/examples/`](src/examples/) for the exact plugin.yml-verified shapes.

```yaml
config: |
  server: "https://my-vault-server"
  path: secret/buildkite
  auth:
    method: "approle"
    role-id: "my-role-id"
```

flattens to:

```
BUILDKITE_PLUGIN_VAULT_SECRETS_SERVER=https://my-vault-server
BUILDKITE_PLUGIN_VAULT_SECRETS_PATH=secret/buildkite
BUILDKITE_PLUGIN_VAULT_SECRETS_AUTH_METHOD=approle
BUILDKITE_PLUGIN_VAULT_SECRETS_AUTH_ROLE_ID=my-role-id
```

The `<NAME>` prefix is derived from the plugin's **repository name**, not the `name:`
field inside `plugin.yml` - stripping a trailing `-buildkite-plugin` suffix, then
uppercasing with hyphens/spaces turned into underscores. A plugin referenced by a full
git URL whose repo doesn't end in `-buildkite-plugin` gets `_GIT` appended (both rules
independently verified against Buildkite's own documentation and by fetching real
plugin repos and checking their derived prefix against what their own hooks read).

**Not implemented:** `BUILDKITE_PLUGIN_CONFIGURATION` (the whole config as one JSON
string) and `BUILDKITE_PLUGIN_VALIDATION`-gated schema validation against `plugin.yml`'s
`configuration` JSON Schema. None of this orb's three verified target plugins' hooks
read either of these - see ["What does not work"](#what-does-not-work).

## Hooks and their CircleCI-native equivalents

`run-hooks` runs whichever of these hook files exist, **in this order**, each as its
own process:

`environment` → `pre-checkout` → `checkout` → `post-checkout` → `pre-command` →
`command` → `post-command` → `pre-artifact` → `post-artifact` → `pre-exit`

The `hooks` parameter is a **filter, not a sequence** - it only controls *which* of
these hook names run; the order you list them in that comma-separated string is
cosmetic and never affects execution order, which is always the fixed lifecycle order
above.

By default it runs everything **except `checkout`, `pre-artifact` and `post-artifact`**
- those three have a CircleCI-native equivalent good enough that overriding it needs a
deliberate opt-in, via the `hooks` parameter:

- **`checkout`** completely replaces Buildkite's own git clone/fetch/checkout logic.
  On CircleCI, the native `checkout` step also wires up your project's checkout keys/
  deploy key - this orb will not silently bypass that. The `plugin` job's `checkout`
  parameter (default `true`) controls the **native** CircleCI checkout; a plugin's own
  `hooks/checkout` only runs if you explicitly add `checkout` to the `hooks` list, and
  even then it runs *after* CircleCI's native checkout (not instead of it, and not
  before it as Buildkite would run it) - fine for a hook that only needs the checkout
  path to exist by the time it runs (this orb's trivy target's `pre-checkout` hook is
  exactly this shape), wrong for a hook that means to replace checkout entirely.
- **`pre-artifact`/`post-artifact`** only fire in real Buildkite when the step has
  `artifact_paths` set. This orb has no equivalent declarative concept - add
  `pre-artifact`/`post-artifact` to `hooks` explicitly and wire your own
  `store_artifacts` (or use the `plugin` job's automatic one, over the shim's artifact
  directory) if a plugin's artifact hooks matter to you.

**Exit-code precedence** is mirrored exactly from Buildkite's own documented lifecycle:
a `pre-command`-or-earlier hook failing wins immediately (`command` never runs);
otherwise `pre-exit` failing always wins last; otherwise `pre-artifact`/`post-artifact`
failing beats a successful command; otherwise `post-command` failing beats the
command's own exit code; otherwise the command's own exit code is final. `pre-exit`
always runs if listed, regardless of any earlier failure - matching Buildkite's own
unconditional cleanup phase.

**`BUILDKITE_COMMAND_EXIT_STATUS`** is exported (into this shell and `$BASH_ENV`) as
soon as the `command` phase finishes, matching real Buildkite - `post-command`,
`pre-artifact`, `post-artifact` and `pre-exit` hooks (and any later native step) can
read it to branch on whether the command itself succeeded, a standard pattern for
coverage-upload/notification-style plugins.

**Telling steps apart when chaining plugins:** every command/job's CircleCI step names
are otherwise fixed strings (e.g. "Running Buildkite plugin hooks"), so calling
`run-hooks`/`plugin` more than once in the same job (see
["Layering and future multi-plugin chaining"](#layering-and-future-multi-plugin-chaining))
produces identically-named steps in the job log. Set the `label` parameter (on
`run-hooks`, `plugin`, or the `plugin` job) to override that step's name - the closest
equivalent this orb has to a Buildkite step's own `label:`.

**The `command` hook and the `command` parameter:** if the plugin defines
`hooks/command`, it runs (and fully replaces the step's own command, exactly as in
real Buildkite). If it doesn't, the `command` parameter runs instead - the equivalent
of a Buildkite step's own `command:` attribute, which only executes when no plugin in
the step supplies a `command` hook. Plugins that only add setup/teardown around your
own command (trivy, vault-secrets, aws-assume-role-with-web-identity - this orb's three
verified targets - are all this shape) leave `command` for you to fill in; plugins that
themselves replace the command (like `docker`/`docker-compose` - see below) don't need it.

## `buildkite-agent` subcommands

Plugin hooks unconditionally shell out to `buildkite-agent`. `install-agent-shim` puts
a reimplementation on `$PATH` - **never a silent no-op**: every subcommand either does
something real and documented below, or exits non-zero with a message naming itself and
explaining why, pointing back here.

| Subcommand | Behaviour | Why |
|---|---|---|
| `artifact upload <glob>` | **Shimmed.** Copies matched files into a local directory (`install-agent-shim`'s `artifact-dir`). | The `plugin` job automatically `store_artifacts`s this directory; command usage needs its own `store_artifacts` step pointed at the same path. |
| `artifact download <glob>` | **Shimmed, same-job only.** Copies from that same local directory. | Can only see artifacts uploaded earlier in *this* job - fetching artifacts a different CircleCI job uploaded needs your own `attach_workspace`/`persist_to_workspace` wiring; there's no imperative cross-job fetch on CircleCI the way Buildkite's real artifact store allows. |
| `meta-data set/get/exists/keys` | **Shimmed, current-job scope only.** A file-based key/value store. | Buildkite's real meta-data store spans the whole build, readable from any job in it; CircleCI jobs don't share a filesystem, so a `get` for a key `set` in a *different* job returns "key does not exist" rather than the real cross-job value - a graceful, honest miss, not a silent success. |
| `env dump` / `env get` | **Shimmed.** | Local introspection only - no control plane involved. |
| `env set` | **Shimmed, with a caveat.** Prints an `export` statement to stdout rather than mutating anything, since a child process can't reach into its parent hook's shell - works only if the hook does `eval "$(buildkite-agent env set ...)"`. | Documented rather than silently dropped. |
| `workdir` (no args) | **Shimmed.** Prints the current directory. | Read-only introspection is safe; changing the caller's cwd from a child process isn't possible, so the setter form hard-fails instead of pretending to work. |
| `annotate` / `annotation` | **Unsupported - hard fails.** | Renders Markdown onto the Buildkite build page UI, which has no CircleCI equivalent surface at all. Have the hook write to a file and `store_artifacts` it instead. |
| `pipeline upload`/etc. | **Unsupported - hard fails.** | Mutates the *running build's* step graph mid-job. CircleCI's nearest analog (the `continuation` orb) only runs before a workflow's other jobs are scheduled, from a separate `setup` job - it cannot be invoked mid-job the way `pipeline upload` can. |
| `step get/update/cancel` | **Unsupported - hard fails.** | No CircleCI primitive exposes "other jobs in this workflow" for imperative mutation from inside a running job. |
| `oidc` | **Unsupported - hard fails.** | Issues a token signed by `agent.buildkite.com`; reconfigure the plugin to use CircleCI's own OIDC tokens instead (`circleci.com/docs/openid-connect-tokens`) against a trust policy scoped to CircleCI's issuer - plugin-specific rework, not a generic shim. See [`src/examples/aws_assume_role_oidc.yml`](src/examples/aws_assume_role_oidc.yml). |
| `secret` | **Unsupported - hard fails.** | Fetches from Buildkite Pipelines Secrets, which doesn't exist here. Use a CircleCI context or project environment variable directly instead. |
| `lock` | **Unsupported - hard fails.** | Coordinates concurrent agents on the same self-hosted host; CircleCI jobs don't share a host this way. Use CircleCI's own concurrency controls at the workflow level. |
| `redactor` | **Unsupported - hard fails.** | Registers values for the real agent's live log-scrubbing filter. There's no hook into CircleCI's log pipeline to redact after the fact - silently no-opping this specifically would risk a secret leaking into logs that a hook believed was being redacted, which is worse than a loud failure. |
| `pause`/`resume`/`stop`/`build`/`job` | **Unsupported - hard fails.** | Controls the agent process or the wider build remotely via Buildkite's control plane. Use CircleCI's own API/UI instead. |
| anything else | **Unsupported - hard fails.** | Not implemented. |

## `docker`/`docker-compose` plugins are deliberately not a target

They're among the highest-usage plugins in the whole Buildkite ecosystem - but only
because Buildkite agents are bare host processes with **no built-in container
isolation**, so those two plugins are Buildkite users' only route to containerized
builds. CircleCI already has this natively (the Docker executor, `machine` with remote
Docker, and the mature `circleci/docker`/`circleci/aws-ecr` orbs) - wrapping them here
would be parity with zero new capability for a CircleCI customer. The one place they'd
carry real value is pure migration parity (not having to hand-translate a
`docker-compose#v5.11.0` step's exact flags on day one of a migration) - a real but
narrow use case, deprioritized against the vendor-integration gaps this orb actually
targets (see below). Nothing stops you from pointing `plugin:` at either of them
yourself - they're ordinary git repos like any other plugin - just don't expect a
better outcome than writing the equivalent native CircleCI Docker step directly.

## Verified targets

Config shapes below are taken directly from each plugin's own `plugin.yml` and README,
not invented - see [`src/examples/`](src/examples/).

- **[`vault-secrets`](https://github.com/buildkite-plugins/vault-secrets-buildkite-plugin)**
  (`vault-secrets#v2.4.2`) - type-aware HashiCorp Vault secret injection (plain env vars,
  `ssh-agent` for SSH keys, `git-credential.helper` for git credentials). Needs a real
  Vault server.
- **[`aws-assume-role-with-web-identity`](https://github.com/buildkite-plugins/aws-assume-role-with-web-identity-buildkite-plugin)**
  (`aws-assume-role-with-web-identity#v1.7.0`) - OIDC-based AWS IAM role assumption. Its
  `environment` hook calls `buildkite-agent oidc`, which this shim hard-fails on - see
  [`src/examples/aws_assume_role_oidc.yml`](src/examples/aws_assume_role_oidc.yml) for
  how to rewire it onto CircleCI's own OIDC tokens instead.
- **[`equinixmetal-buildkite/trivy`](https://github.com/equinixmetal-buildkite/trivy-buildkite-plugin)**
  (`equinixmetal-buildkite/trivy#v1.22.0`) - Trivy vulnerability scanning. **Credential-free**
  - it downloads its own scanner binary and scans the checked-out filesystem - which is
  why this is also the orb's own CI test (see [`.circleci/test-deploy.yml`](.circleci/test-deploy.yml)).

## What does not work

- **`buildkite-agent pipeline upload` and `step`** - no CircleCI equivalent at all; see
  the subcommand table above.
- **Cross-job `meta-data`** - shimmed within a single job, not across jobs.
- **`annotate`** - no CircleCI UI surface to render onto.
- **Polyglot hooks** (a hook with a non-bash shebang) - real `buildkite-agent` skips its
  own env-diffing wrapper for these; this orb's `run-hooks` always dot-sources hooks
  into a bash wrapper regardless of shebang, so a genuinely non-bash hook (Ruby, Python,
  Node, ...) will likely misbehave. None of this orb's three verified targets are polyglot.
- **Vendored plugins** - Buildkite distinguishes a plugin referenced by a path inside
  your own checked-out repo (whose `environment` hook runs *after* checkout) from a
  fetched one (whose `environment` hook runs *before*). This orb always fetches via git
  and always treats the plugin as non-vendored - fine for the vast majority of plugins,
  wrong if you specifically rely on the vendored-plugin hook-ordering nuance.
- **`BUILDKITE_PLUGIN_VALIDATION`** - a plugin's `plugin.yml` can carry a JSON Schema
  under `configuration`; real Buildkite validates config against it, but only when this
  flag is explicitly enabled (default `false` even on real Buildkite). This orb doesn't
  implement that validation at all, in v1.
- **The derived `<NAME>` for a subdirectory plugin** (`repo.git/subdir#ref`) -
  Buildkite's own docs never state whether this comes from the subdirectory's name or
  the outer repo's name, and no real multi-plugin-monorepo example was found to confirm
  either way. This orb uses the subdirectory's name (see the comment in
  [`fetch-plugin.sh`](src/scripts/fetch-plugin.sh)); flag it if a real example proves
  that wrong.
- **Very old bash images** - `run-hooks`' environment-diffing relies on `export -p`
  rendering a value with embedded newlines or quotes as a single `$'...'`-quoted
  (ANSI-C) line, which every bash 4.x/5.x tested against (including `cimg/base`'s
  bash 5.2) does - verified end-to-end with both a newline-bearing and a
  quote-bearing value threading correctly through `$BASH_ENV` into a later step. An
  image old enough to predate that quoting behavior could misbehave; none of this
  orb's three verified targets are affected either way.
- **Multi-line YAML scalars, flow-style config, anchors/aliases, same-line trailing
  `#` comments** - see [Config flattening](#config-flattening).
- **The `docker`/`docker-compose` plugins** - deliberately not a target; see above.
- **No automatic `store_test_results` default.** Real Buildkite Test Engine/Analytics is
  an HTTP API upload (`analytics-api.buildkite.com/v1/uploads`, OIDC- or token-authed),
  performed by a plugin (the Tests plugin/bktec, or the Test Collector plugin) that
  itself decides where its JUnit/JSON input lives - there's no fixed filesystem path any
  Buildkite plugin is expected to write test output to, unlike artifacts (where this
  orb's own agent-shim reimplementation gives it a real directory to default against -
  see `store-artifacts` above). No local shim for the Test Analytics API exists in this
  orb, so there's nothing to point a default at; add your own `store_test_results` step
  (or `post-steps:` on the `plugin` job) if you know the specific plugin's own output path.

## Interleaving native CircleCI steps around the plugin's hooks

The `buildkite/plugin` **job** (only when invoked from a workflow's `jobs:` list, not the
`plugin` **command** inside another job's own `steps:`) accepts CircleCI's own built-in
`pre-steps`/`post-steps` arguments - available on every 2.1+ job, not something this orb
declares. Pass them at the call site:

```yaml
- buildkite/plugin:
    plugin: "equinixmetal-buildkite/trivy#v1.22.0"
    pre-steps:
      - run: echo "before checkout AND before the plugin's hooks"
    post-steps:
      - run: echo "after the plugin's hooks; their env diff is already in $BASH_ENV"
```

**One real platform caveat:** `pre-steps` run before **every** step in the job, including
this job's own internal `checkout` - not just before the plugin's hooks. If a pre-step
needs the repo checked out first, either do that checkout yourself inside the pre-step, or
use `checkout: false` on the job plus an explicit `checkout` as the first entry of
`pre-steps`:

```yaml
- buildkite/plugin:
    plugin: "equinixmetal-buildkite/trivy#v1.22.0"
    checkout: false
    pre-steps:
      - checkout
      - run: echo "runs after checkout, still before the plugin's hooks"
    post-steps:
      - run: echo "after the plugin's hooks"
```

Need several native steps and several plugin invocations interleaved in a specific order
within one job? Reach for the `fetch-plugin`/`configure`/`install-agent-shim`/`run-hooks`
commands (or the aggregate `plugin` command) in a hand-rolled job instead - see
[Layering and future multi-plugin chaining](#layering-and-future-multi-plugin-chaining).

## Layering and future multi-plugin chaining

Each command does one job and reads/writes plain environment variables and
`$BASH_ENV` - `fetch-plugin` sets `BUILDKITE_PLUGIN_ROOT`/`BUILDKITE_PLUGIN_ENV_PREFIX`,
`configure` reads the latter, `run-hooks` reads the former. Nothing is baked into a
single monolithic script. Calling `fetch-plugin` → `configure` → `run-hooks` more than
once in the same job (with a different `plugin-dir` each time to avoid colliding
clones) approximates chaining several plugins' hooks today; a `cci-labs/ci-bridge`-style
shared orb, if one exists later, could formalize that into its own command without a
breaking change here.

## Legal / compliance

This orb does **not** bundle, vendor, install, or invoke the `buildkite-agent` binary.
Everything in `run-hooks`, `configure`, `fetch-plugin` and the `buildkite-agent` shim is
this orb's own implementation of the publicly documented plugin/hook contract
(`buildkite.com/docs/agent/hooks`, `buildkite.com/docs/pipelines/integrations/plugins`)
and independently observed, real-world plugin behaviour - none of it copied from
`buildkite/agent`'s source. Buildkite's Terms of Service restrict combining the
Buildkite Agent with other software to create a new product; this orb never touches
that binary or Buildkite's control plane at all, so that restriction doesn't apply to
it. It does execute the separately MIT-licensed bash of whichever plugin repository you
point it at, exactly as cloning and running any other open-source shell script would.

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/buildkite) - all versions, executors, commands, and jobs.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration) - docs for using, creating, and publishing CircleCI orbs.

[Buildkite plugin docs](https://buildkite.com/docs/pipelines/integrations/plugins) - the contract this orb reimplements.

## How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/buildkite-orb/issues) to and [pull requests](https://github.com/CircleCI-Labs/buildkite-orb/pulls) against this repository!

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's `<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb that can still pass `circleci orb validate` -- a false green with no other symptom. Run `scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack` workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a job parameter literally named `pre-steps` or `post-steps` outright -- this only surfaces under `orb validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it. If you're adding a new job parameter, don't pick either name.

## How to Publish An Update
1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info cci-labs/buildkite | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/CircleCI-Labs/buildkite-orb/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
      - We will have an opportunity to change this before we publish if needed after the next step.
4.  Click _"+ Auto-generate release notes"_.
    - This will create a summary of all of the merged pull requests since the previous release.
    - If you have used _[Conventional Commit Messages](https://conventionalcommits.org/)_ it will be easy to determine what types of changes were made, allowing you to ensure the correct version tag is being published.
5. Now ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_.
    - This will push a new tag and trigger your publishing pipeline on CircleCI.
