# Limits

## `docker`/`docker-compose` plugins are deliberately not a target

They're among the highest-usage plugins in the whole Buildkite ecosystem, but CircleCI already
has native container support with zero new capability gained by wrapping them here; see
[`docs/ROADMAP.md`](ROADMAP.md) item 1 for the full reasoning. Nothing stops you from
pointing `plugin:` at either of them yourself (they're ordinary git repos like any other plugin),
just don't expect a better outcome than writing the equivalent native CircleCI Docker step
directly.

## Verified targets, and what "verified" means for each

Config shapes below are taken directly from each plugin's own `plugin.yml` and README, not
invented; see [`src/examples/`](../src/examples/). **"Verified" is not one uniform claim across
all three**: only one of them is actually fetched, configured, and run in this orb's own CI;
the other two are config-shape-verified only, and one of those is documented as never running
at all against this orb as written:

- **[`equinixmetal-buildkite/trivy`](https://github.com/equinixmetal-buildkite/trivy-buildkite-plugin)**
  (`equinixmetal-buildkite/trivy#v1.22.0`): Trivy vulnerability scanning. **Actually run, green,
  credential-free, end-to-end**, in this orb's own CI: fetch, configure, cross-hook env
  threading, a real scan. It downloads its own scanner binary and scans the checked-out
  filesystem, needing nothing else. See [`.circleci/test-deploy.yml`](../.circleci/test-deploy.yml).
  This is the one target this documentation's claims are fully backed by a real, credential-free CI
  run.
- **[`vault-secrets`](https://github.com/buildkite-plugins/vault-secrets-buildkite-plugin)**
  (`vault-secrets#v2.4.2`): type-aware HashiCorp Vault secret injection (plain env vars,
  `ssh-agent` for SSH keys, `git-credential.helper` for git credentials). **Fetch-only, never
  configured or run in CI**: it needs a real Vault server this repo doesn't have. The `fetch-plugin`
  step (resolving the reference, cloning the real plugin repo) is exercised in CI; its hooks
  are not.
- **[`aws-assume-role-with-web-identity`](https://github.com/buildkite-plugins/aws-assume-role-with-web-identity-buildkite-plugin)**
  (`aws-assume-role-with-web-identity#v1.7.0`): OIDC-based AWS IAM role assumption. **Never run
  at all, and documented as hard-failing as written**: its `environment` hook calls
  `buildkite-agent oidc`, which this shim hard-fails on by design (see the
  [subcommand table](ARCHITECTURE.md#buildkite-agent-subcommands)). See
  [`src/examples/aws_assume_role_oidc.yml`](../src/examples/aws_assume_role_oidc.yml)
  for the rework needed to rewire it onto CircleCI's own OIDC tokens instead. Listed here as a
  documented config-shape reference and a known gap, not a working target.

## Limits

- **`buildkite-agent pipeline upload` and `step`**: no CircleCI equivalent at all; see
  the [subcommand table](ARCHITECTURE.md#buildkite-agent-subcommands).
- **Cross-job `meta-data`**: shimmed within a single job, not across jobs.
- **`annotate`**: no CircleCI UI surface to render onto.
- **Polyglot hooks** (a hook with a non-bash shebang): real `buildkite-agent` skips its
  own env-diffing wrapper for these; this orb's `run-hooks` always dot-sources hooks
  into a bash wrapper regardless of shebang, so a genuinely non-bash hook (Ruby, Python,
  Node, ...) will likely misbehave. None of this orb's three verified targets are polyglot.
- **Vendored plugins**: Buildkite distinguishes a plugin referenced by a path inside
  your own checked-out repo (whose `environment` hook runs *after* checkout) from a
  fetched one (whose `environment` hook runs *before*). This orb always fetches via git
  and always treats the plugin as non-vendored: fine for the vast majority of plugins,
  wrong if you specifically rely on the vendored-plugin hook-ordering nuance.
- **`BUILDKITE_PLUGIN_VALIDATION`**: a plugin's `plugin.yml` can carry a JSON Schema
  under `configuration`; real Buildkite validates config against it, but only when this
  flag is explicitly enabled (default `false` even on real Buildkite). This orb doesn't
  implement that validation at all, in v1.
- **The derived `<NAME>` for a subdirectory plugin** (`repo.git/subdir#ref`):
  Buildkite's own docs never state whether this comes from the subdirectory's name or
  the outer repo's name, and no real multi-plugin-monorepo example was found to confirm
  either way. This orb uses the subdirectory's name (see the comment in
  [`fetch-plugin.sh`](../src/scripts/fetch-plugin.sh)); flag it if a real example proves
  that wrong.
- **Very old bash images**: `run-hooks`' environment-diffing relies on `export -p`
  rendering a value with embedded newlines or quotes as a single `$'...'`-quoted
  (ANSI-C) line, which every bash 4.x/5.x tested against (including `cimg/base`'s
  bash 5.2) does, verified end-to-end with both a newline-bearing and a
  quote-bearing value threading correctly through `$BASH_ENV` into a later step. An
  image old enough to predate that quoting behavior could misbehave; none of this
  orb's three verified targets are affected either way.
- **Multi-line YAML scalars, flow-style config, anchors/aliases, same-line trailing
  `#` comments**: see [Config flattening](ARCHITECTURE.md#config-flattening).
- **The `docker`/`docker-compose` plugins**: deliberately not a target; see above.
- **The plugin-clone cache never reuses an unpinned reference.** `plugin-cache`'s key
  is the plugin reference string itself, with no fallback key: a good match for how
  Buildkite itself treats plugin sources, but only if the reference is pinned (`#tag`
  or `#sha`). An unpinned reference (a mutable branch, or no `#ref` at all) would
  otherwise cache the clone **once** and then reuse it forever, since the key never
  changes on its own, permanently pinning you to whatever commit happened to be at
  the branch tip on the very first run, which is worse than not caching at all (an
  uncached run at least re-fetches the branch tip every time). `fetch-plugin.sh`
  closes that gap by refusing to reuse a cached/restored clone whenever no ref is
  pinned, loudly, in the job log, so an unpinned reference always re-clones fresh,
  exactly as if `plugin-cache: false`. Pin a tag or commit SHA to get both a
  reproducible build and a working cache.
- **No automatic `store_test_results` default, but an explicit opt-in exists.** Real
  Buildkite Test Engine/Analytics is an HTTP API upload
  (`analytics-api.buildkite.com/v1/uploads`, OIDC- or token-authed), performed by a plugin (the
  Tests plugin/bktec, or the Test Collector plugin) that itself decides where its JUnit/JSON
  input lives. There's no fixed filesystem path any Buildkite plugin is expected to write test
  output to, unlike artifacts (where this orb's own agent-shim reimplementation gives it a real
  directory to default against; see `store-artifacts` in [Commands](COMMANDS.md)). No local shim
  for the Test Analytics API exists in this orb, so there's still no *default* path to point at,
  but once *you* know your specific plugin's own JUnit XML output path, set `test-results-path` on
  `plugin` (command or job) and `store_test_results` runs against it after the hooks finish.
  Left empty (the default), nothing runs.

## Trust model: native execution, no container boundary

Unlike the sibling `harness`/`bitbucket` orbs (which run a vendor's Docker image, with whatever
sandboxing a plain container gives you), a Buildkite plugin's hooks run **directly in the job's
own shell/process** on the `docker`/`machine`/`docker-toolchains` executor you chose. There is
no container boundary between the plugin's code and the rest of the job at all. A plugin's hook
has everything the job has: the full checkout, every sourced context/project secret, network
access, and on the `machine` executor, the Docker socket and host filesystem outright. This is
inherent to how Buildkite plugins work (the real `buildkite-agent` runs them the same way, as
bare host processes); it is not a gap this orb could close even if it wanted to, but it
means this orb is a strictly higher-trust ask of you than the docker-sandboxed `harness`/
`bitbucket` bridges. Treat every plugin you point `plugin:` at the same way you'd treat a
third-party dependency you added directly to your build.

**No value this orb exports is ever masked in logs.** Whatever a hook writes into `$BASH_ENV`
through the env-diff threading described in [Hooks and their CircleCI-native equivalents](ARCHITECTURE.md#hooks-and-their-circleci-native-equivalents),
and anything it stores via the `meta-data` shim, is exported verbatim and unredacted. CircleCI's
own log masking only catches an **exact match** against a registered context or project secret;
a value a plugin derived from a secret, a URL with credentials embedded in it, or a secret
concatenated with other text is not something masking will catch. Since hooks run natively here
with the whole job's environment available to them, treat every value a plugin sets as public log
content, and don't rely on this orb or on CircleCI to hide it for you.

This orb's `buildkite-agent` shim is its own implementation of the publicly documented plugin/hook contract, not a copy of `buildkite/agent`'s source; it executes the separately-licensed shell scripts of whatever plugin repository you point `plugin:` at, the same as cloning and running any other open-source script.
