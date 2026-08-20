# Getting Started

## Scope: one plugin per call, not a whole pipeline

This orb runs **one plugin per step**, faithfully: it is not a Buildkite pipeline
emulator. It doesn't understand `pipeline.yml`, doesn't chain multiple plugins'
`command` hooks together the way a Buildkite step with a `plugins:` array does, and
doesn't touch Buildkite's control plane in any way (there's no account to touch; this
orb never contacts `agent.buildkite.com`). What it gives you:

- **Migration parity**: a step that already works as a Buildkite plugin can run,
  largely unmodified, on CircleCI while you migrate the rest of the pipeline.
- **Access to vendor integrations that only exist as Buildkite plugins**: some
  integrations (type-aware Vault secret routing, for example) don't have an
  equivalent, comparably-deep, official CircleCI orb today.

If you need several plugins chained together the way Buildkite's `plugins:` array
does, call this orb's commands more than once in the same job; see
[Layering and future multi-plugin chaining](COMMANDS.md#layering-and-future-multi-plugin-chaining).

## Choosing an executor

Three executors, all opt-in (no default plugin-independent choice is forced on you):

| Executor | When |
|---|---|
| `buildkite/docker` (default) | Most plugin hooks: plain bash, nothing more than `cimg/base` gives you. Starts faster, costs less. |
| `buildkite/machine` | The hooks themselves shell out to `docker`/`docker-compose`, need a loopback Docker daemon, or need kernel-level access the `docker` executor's container can't provide. |
| `buildkite/docker-toolchains` | The hooks assume a real toolchain (node, go, ruby, aws-cli, gcloud, `buildkite-cli`) is already on `PATH`, the same failure class `fetch-plugin`'s own `requirements:` warning flags. |

`buildkite/docker-toolchains` wraps Buildkite's own `agent-base` image
(`github.com/buildkite/agent-base-images`, MIT-licensed, rebuilt **daily**, amd64+arm64),
pulled from ECR Public specifically to dodge Docker Hub's anonymous-pull rate limit; see
[`docs/ROADMAP.md`](ROADMAP.md)'s "Vendor-image layering" for why this is the one sibling
orb that adopts a vendor convenience image at all. **One real trap in Buildkite's own docs, found
while researching this:** their docs (`buildkite.com/docs/agent/buildkite-hosted/linux/custom-agent-images`)
point at `buildkite/hosted-agent-base`, a *different*, stale image (unmaintained for over
a year as of this writing). The actively-maintained successor this orb actually uses is
`buildkite/agent-base` from a different GitHub repo. Don't follow that specific link in
Buildkite's own docs expecting it to match what's below.

```yaml
- buildkite/plugin:
    plugin: "some-org/some-plugin#v1.0.0"
    executor: buildkite/docker-toolchains
```

Still ~1GB; prefer the plain `buildkite/docker` executor unless a plugin's own hooks
genuinely need this. See the executor's own description for the exact tool list and how
to switch to the smaller `-hosted` tag (drops node/go/ruby, keeps git/jq/python3/aws-
cli/gcloud) if a plugin needs less than the full toolchain.

## Interleaving native CircleCI steps around the plugin's hooks

The `buildkite/plugin` **job** (only when invoked from a workflow's `jobs:` list, not the
`plugin` **command** inside another job's own `steps:`) accepts CircleCI's own built-in
`pre-steps`/`post-steps` arguments, available on every 2.1+ job, not something this orb
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
this job's own internal `checkout`, not just before the plugin's hooks. If a pre-step
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
commands (or the aggregate `plugin` command) in a hand-rolled job instead; see
[Layering and future multi-plugin chaining](COMMANDS.md#layering-and-future-multi-plugin-chaining).

## Passing data across jobs

Both cross-job mechanisms already named in the [subcommand table](ARCHITECTURE.md#buildkite-agent-subcommands)
(`meta-data`, this-job-only; `artifact download`, same-job only) are job-scoped, matching
real Buildkite's own agent model less than they might first appear. Two real, native
CircleCI mechanisms cover the "I need this value in a later job" case without any orb
change:

- **Passing a value to a downstream job**: after the hooks run, write the value you need to a
  file and `persist_to_workspace` it, then `attach_workspace` in the downstream job and read the
  file with a plain `run` step.
- **Branching which jobs run based on an upstream job's output** (a genuine workflow-level
  conditional): CircleCI has no native construct for this. The closest real mechanism is a setup
  workflow plus the
  [`circleci/continuation`](https://circleci.com/developer/orbs/orb/circleci/continuation) orb,
  where an early job computes a value and calls `continuation/continue` with a config whose
  `workflows:` block is shaped by that value. See [`docs/ROADMAP.md`](ROADMAP.md)'s
  "Workspace / parallelism fit" for why this wasn't built as an orb feature.
