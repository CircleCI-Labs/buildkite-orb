# Roadmap / deferred design decisions

This file records the things a recent audit of the `cci-labs` ecosystem-bridge orb family
(2026-08) found worth doing to `buildkite-orb`, but that this orb deliberately does **not** do,
and why, so the decision is visible in the repo instead of living only in a chat transcript or a
PR description that ages out. It also carries forward the reasoning behind a handful of
scope/design calls that already shipped, so a future contributor doesn't have to re-derive "why is
it built this way" from scratch.

None of the items below are secretly half-built. If you pick one up, treat this as the starting
brief, not a patch to apply.

## Deferred / not implemented

### 1. `docker`/`docker-compose` plugins

**What it would do:** run Buildkite's own `docker`/`docker-compose` plugins through this orb like
any other plugin, the way a migrating pipeline's `plugins:` array would expect.

**Why it's deferred:** these two are among the highest-usage plugins in the whole Buildkite
ecosystem, but only because Buildkite agents are bare host processes with **no built-in container
isolation**: those two plugins are Buildkite users' only route to containerized builds there.
CircleCI already has this natively (the Docker executor, `machine` with remote Docker, and the
mature `circleci/docker`/`circleci/aws-ecr` orbs), so wrapping them here would be parity with zero
new capability for a CircleCI customer. The one place they'd carry real value is pure migration
parity (not having to hand-translate a `docker-compose#v5.11.0` step's exact flags on day one of a
migration), a real but narrow use case, deprioritized against the vendor-integration gaps this
orb actually targets (type-aware Vault secret routing and similar plugins with no comparably-deep
official CircleCI orb equivalent today).

**What shipped instead:** nothing stops you from pointing `plugin:` at either of them yourself:
they're ordinary git repos like any other plugin. Just don't expect a better outcome than
writing the equivalent native CircleCI Docker step directly.

**If someone picks this up:** the migration-parity case is the actual justification, so scope it
around "translate this specific `docker-compose#vX` config shape correctly," not "these plugins
are broken here": as written today they aren't broken, they're just not a better answer than
CircleCI's own native tooling.

### 2. `BUILDKITE_PLUGIN_CONFIGURATION` and `BUILDKITE_PLUGIN_VALIDATION` schema checking

**What it would do:** also export the plugin's entire flattened config as one JSON string under
`BUILDKITE_PLUGIN_CONFIGURATION`, and validate `config:` against `plugin.yml`'s own `configuration`
JSON Schema when `BUILDKITE_PLUGIN_VALIDATION` is set (real Buildkite defaults this to `false` too).

**Why it's deferred:** none of this orb's three verified target plugins' hooks read either
mechanism: `configure`'s per-key `BUILDKITE_PLUGIN_<NAME>_<KEY>` flattening (see "Config
flattening") is what every real config in the vault-secrets, aws-assume-role-with-web-identity,
and trivy plugins' own READMEs actually needs, and building JSON-Schema validation with no target
plugin to verify it against would be unverified surface area for a feature nothing here exercises.

**What shipped instead:** the gap is named explicitly under ["Limits"](#limits) rather than left
to be discovered by a hook that silently gets nothing.

**If someone picks this up:** a plugin that specifically needs `BUILDKITE_PLUGIN_CONFIGURATION`
would be the right forcing function: build against a real target, the same discipline every
other piece of this orb was held to (see
["Verified targets"](LIMITS.md#verified-targets-and-what-verified-means-for-each) in LIMITS.md).

### 3. Formalizing multi-plugin chaining into a shared command

**What it would do:** give this orb (or a shared `cci-labs/ci-bridge`-style orb, if one exists
later) a first-class "chain N plugins" command instead of the current pattern of calling
`fetch-plugin` -> `configure` -> `run-hooks` more than once in the same job by hand.

**Why it's deferred:** each command already does one job and reads/writes plain environment
variables and `$BASH_ENV`. Nothing is baked into a single monolithic script, so calling the
sequence more than once (with a different `plugin-dir` each time to avoid colliding clones)
already approximates chaining today with zero orb changes. There wasn't a concrete second use
case pushing past that approximation yet.

**What shipped instead:** the granular commands themselves, already shaped so this formalization
could be added later without a breaking change. See "Command-split decisions" below.

**If someone picks this up:** watch for whether the real need is "run N plugins in strict
sequence" (today's pattern already covers this) or something with actual cross-plugin
interaction (e.g. one plugin's hook needing another's `BUILDKITE_PLUGIN_*` vars): the latter is
a materially different, harder design problem than the former.

## Limitations reassessment (2026-08)

Four cross-cutting questions came up while auditing this orb against its `cci-labs` siblings.
Each was already answered somewhere in this orb's design; this section is where that reasoning
lives now, instead of being spread across README prose a user has to hunt for.

### Image caching economics

`buildkite/machine`'s `docker_layer_caching` parameter defaults to **off**, matching every sibling
orb's own DLC default. Unlike the sibling `harness`/`bitbucket` orbs, though, this orb's own
executors don't `docker run` a vendor image at all: a plugin's hooks run natively (see "Trust
model" below), so DLC here is only relevant on the rare occasion a plugin's own hooks build or
run Docker images themselves (the one scenario the parameter's own description names). None of
this orb's three verified target plugins do this, so there's no real workload to measure a
recommendation against yet; turn it on if your specific plugin's hooks build/run images and you
observe repeated image pulls costing real time, using the same all-or-nothing-vs-per-layer
tradeoff the sibling orbs document for their own Docker-running executors.

### Command-split decisions

`plugin` decomposes into four commands (`fetch-plugin` -> `map-env` -> `install-agent-shim` ->
`configure` -> `run-hooks`, five including the aggregate) specifically because each one reads/
writes plain environment variables and `$BASH_ENV` with nothing baked into a single monolithic
script. `fetch-plugin` sets `BUILDKITE_PLUGIN_ROOT`/`BUILDKITE_PLUGIN_ENV_PREFIX`, `configure`
reads the latter, `run-hooks` reads the former: that's what lets calling the sequence more than
once (each with its own `plugin-dir`) already approximate multi-plugin chaining today, and what
would let a future shared orb formalize that into its own command without a breaking change here
(see item 3 above). See "How it works" in [ARCHITECTURE.md](ARCHITECTURE.md) and
["Layering and future multi-plugin chaining"](COMMANDS.md#layering-and-future-multi-plugin-chaining)
for the current mechanism.

### Workspace / parallelism fit

This orb's env-diff-threading mechanism (`$BASH_ENV`) is job-scoped: it doesn't cross a job
boundary on its own, matching real Buildkite's own agent model less than it might first appear
(Buildkite's `meta-data` is build-wide; this orb's shim of it is this-job-only, and `artifact
download` is same-job-only too: see the `buildkite-agent` subcommand table). Passing a value to
a downstream job is already fully solved with zero orb changes: write it to a file after the hooks
run, `persist_to_workspace` it, `attach_workspace` downstream. **Branching which jobs *run*, based
on an upstream job's output, was considered and explicitly not solved here.** CircleCI has no
native construct for a genuine workflow-level conditional at all, orb or no orb; the closest real
mechanism is a setup workflow plus the `circleci/continuation` orb. See
["Passing data across jobs"](GETTING-STARTED.md#passing-data-across-jobs) in GETTING-STARTED.md
for the current worked examples of both mechanisms.

### Vendor-image layering

`buildkite/docker-toolchains` wraps Buildkite's own `agent-base` image
(`github.com/buildkite/agent-base-images`, MIT-licensed, rebuilt daily, amd64+arm64), pulled from
ECR Public specifically to dodge Docker Hub's anonymous-pull rate limit. Checked directly against
all four `cci-labs` ecosystem-bridge orbs' own vendor-image research: this was the one clean win
among them. Unlike the sibling `harness`/`bitbucket` orbs (where every plugin/pipe is already its
own purpose-built image, so there's nothing to layer) and unlike `bitrise` (whose only public
vendor image is a multi-year-stale snapshot), Buildkite's own base image is current, permissively
licensed, and genuinely fills the gap `fetch-plugin`'s own missing-`requirements:` warning already
flags. One real trap found while researching this and worth repeating here: Buildkite's own docs
(`buildkite.com/docs/agent/buildkite-hosted/linux/custom-agent-images`) point at
`buildkite/hosted-agent-base`, a different, stale image (unmaintained for over a year as of this
writing): the actively-maintained successor this orb actually uses is `buildkite/agent-base`
from a different GitHub repo. See ["Choosing an executor"](GETTING-STARTED.md#choosing-an-executor)
for the current user-facing guidance and the exact tag/tool tradeoffs.
