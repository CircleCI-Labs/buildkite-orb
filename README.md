# Buildkite Orb (Unofficial)

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/buildkite-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/buildkite-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/buildkite.svg)](https://circleci.com/developer/orbs/orb/cci-labs/buildkite) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/buildkite-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

Run **one [Buildkite plugin](https://buildkite.com/docs/pipelines/integrations/plugins)** as a single step inside an otherwise-native CircleCI job or workflow: no Buildkite account, agent, or control plane involved. This orb resolves a plugin's git reference, clones it, flattens your config into the exact `BUILDKITE_PLUGIN_*` environment variables Buildkite itself would set, and runs the plugin's own hook scripts in Buildkite's documented order, threading environment changes forward between hooks the same way `buildkite-agent` does. It runs **one plugin per step**; it is not a Buildkite pipeline emulator (see [Getting Started](docs/GETTING-STARTED.md) for the exact scope).

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ⚠️ **Not yet used by production CircleCI customers.** This orb is currently dev-published only. What *is* verified: `equinixmetal-buildkite/trivy` (a real vulnerability scanner, fully credential-free) runs green end-to-end in this repo's own CI: fetch, configure, run hooks, cross-hook env threading, into a real scan. See [Verified targets](docs/LIMITS.md#verified-targets-and-what-verified-means-for-each) for exactly what is and isn't proven among this orb's three named targets.
-   ❌ **not** officially supported by CircleCI support

---

## Contents

- [Architecture](docs/ARCHITECTURE.md): how it works, the environment mapping, hooks and the agent shim
- [Getting Started](docs/GETTING-STARTED.md): scope, executor choices, interleaving native steps, passing data across jobs
- [Commands](docs/COMMANDS.md): the complete command/job/parameter reference
- [Migrating from Buildkite](docs/MIGRATING.md): mapping a real `pipeline.yml` step onto this orb
- [Limits](docs/LIMITS.md): what doesn't work, the trust model, and verified targets
- [Roadmap](docs/ROADMAP.md): items deliberately scoped out, with the reasoning kept

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
executor overrides, and [Getting Started](docs/GETTING-STARTED.md) for the fuller walkthrough.

## Commands and jobs

| Name | Kind | What it does |
|---|---|---|
| `plugin` | command, job | The aggregate most users want: fetch, map env, install the agent shim, flatten config, run hooks. |
| `fetch-plugin` | command | Resolves the plugin reference and git-clones it at the pinned ref, cached. |
| `map-env` | command | Exports the CircleCI to Buildkite variable mapping into `$BASH_ENV`. |
| `install-agent-shim` | command | Puts a `buildkite-agent` reimplementation on `$PATH`. |
| `configure` | command | Flattens `config:` onto `BUILDKITE_PLUGIN_<NAME>_<KEY>` variables. |
| `run-hooks` | command | Runs the plugin's `hooks/*` files in Buildkite's fixed lifecycle order, with env-diff threading. |

Full parameter tables for every command and job are in [docs/COMMANDS.md](docs/COMMANDS.md).

## Limits, in brief

- This orb runs **one plugin per step**: it doesn't chain multiple plugins' hooks together the way a Buildkite step's `plugins:` array does, and it never touches Buildkite's control plane.
- `docker`/`docker-compose` plugins are deliberately not a target; CircleCI already has native container support.
- A plugin's hooks run directly in the job's own shell/process, with no container boundary: treat every plugin you point `plugin:` at as trusted as a dependency you added directly to your build.
- No value this orb exports is ever masked in logs; treat every value a plugin sets as public log content.

Full detail, plus the verified-targets breakdown, in [docs/LIMITS.md](docs/LIMITS.md).

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/buildkite): all versions, executors, commands, and jobs.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration): docs for using, creating, and publishing CircleCI orbs.

[Buildkite plugin docs](https://buildkite.com/docs/pipelines/integrations/plugins): the contract this orb reimplements.

## How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/buildkite-orb/issues) and [pull requests](https://github.com/CircleCI-Labs/buildkite-orb/pulls) against this repository. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for items deliberately scoped out of past passes, with the reasoning recorded rather than lost.

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's `<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb that can still pass `circleci orb validate`: a false green with no other symptom. Run `scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack` workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a job parameter literally named `pre-steps` or `post-steps` outright; this only surfaces under `orb validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it. If you're adding a new job parameter, don't pick either name.

## How to Publish An Update

1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info cci-labs/buildkite | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/CircleCI-Labs/buildkite-orb/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag (ex: v1.0.0).
      - There will be an opportunity to change this before publishing, if needed, after the next step.
4.  Click _"+ Auto-generate release notes."_
    - This creates a summary of all of the merged pull requests since the previous release.
    - Using [Conventional Commit Messages](https://conventionalcommits.org/) makes it easy to determine what types of changes were made, so you can confirm the correct version tag is being published.
5. Confirm the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release."_
    - This pushes a new tag and triggers the publishing pipeline on CircleCI.
