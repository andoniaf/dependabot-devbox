# dependabot-devbox

[![Gem Version](https://badge.fury.io/rb/dependabot-devbox.svg)](https://badge.fury.io/rb/dependabot-devbox)

Automatically update [Devbox](https://www.jetify.com/devbox) package versions and open PRs — just like Dependabot, but for `devbox.json`.

This is a standalone implementation of devbox ecosystem support built on top of `dependabot-common`. It exists while [official support is pending](https://github.com/dependabot/dependabot-core/pull/15440) in upstream dependabot-core. When that PR merges, you can switch to the native Dependabot experience.

## Quickstart

Add a workflow to your repo:

```yaml
# .github/workflows/devbox-updates.yml
name: Devbox dependency updates

on:
  schedule:
    - cron: "0 8 * * 1"  # every Monday at 08:00 UTC
  workflow_dispatch:

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: andoniaf/dependabot-devbox@v0
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

That's it. On each run it will:
1. Parse your `devbox.json`
2. Check Nixhub for newer versions of each package
3. Open a separate PR for every package that can be updated

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `github-token` | yes | — | Token used to open PRs (`secrets.GITHUB_TOKEN` works) |
| `directory` | no | `/` | Path to the directory containing `devbox.json` |
| `base-branch` | no | repo default | Branch to open PRs against |
| `gem-version` | no | latest | Pin a specific `dependabot-devbox` gem version |
| `group-updates` | no | `false` | Group minor/patch updates into a single PR; each major update still gets its own PR. When `false`, every update (major or not) gets its own PR. |
| `cooldown-days` | no | `7` | Skip a package version until it has been released for this many days. Set to `0` to disable. |
| `exclude-packages` | no | — | Space/comma-separated package names to skip (e.g. `"go nodejs"`) |

### Grouping and cooldown

```yaml
- uses: andoniaf/dependabot-devbox@v0
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    group-updates: "true"
    cooldown-days: "7"
```

With `group-updates: "true"`, a run that finds `postgresql 17.7 → 17.10`, `nodejs 24 → 26`, and `pnpm 10 → 11` opens one PR bundling the `postgresql` minor bump, plus one individual PR each for the `nodejs` and `pnpm` major bumps.

## Multiple directories

Run the action once per directory:

```yaml
strategy:
  matrix:
    directory: ["/", "/services/api", "/services/worker"]
steps:
  - uses: actions/checkout@v4
  - uses: andoniaf/dependabot-devbox@v0
    with:
      github-token: ${{ secrets.GITHUB_TOKEN }}
      directory: ${{ matrix.directory }}
```

## Excluding packages

Skip specific packages, e.g. one you pin and bump by hand:

```yaml
with:
  github-token: ${{ secrets.GITHUB_TOKEN }}
  exclude-packages: "go nodejs"
```

## Using the gem directly

```ruby
gem "dependabot-devbox"
```

```ruby
require "dependabot/devbox"

# The gem registers all the standard Dependabot classes:
# Dependabot::FileFetchers.for_package_manager("devbox")
# Dependabot::FileParsers.for_package_manager("devbox")
# Dependabot::UpdateCheckers.for_package_manager("devbox")
# Dependabot::FileUpdaters.for_package_manager("devbox")
```

Or run the bundled script directly:

```sh
GITHUB_REPOSITORY=owner/repo \
GITHUB_ACCESS_TOKEN=ghp_... \
dependabot-devbox-update
```

## How it works

- **FileFetcher** — fetches `devbox.json` (and `devbox.lock` if present) from GitHub
- **FileParser** — parses `name@constraint` package entries (supports JSONC with comments/trailing commas)
- **UpdateChecker** — queries [Nixhub](https://search.devbox.sh) for available versions, respects constraint precision (`3.10` → minor-pinned, `3.10.15` → exact-pinned, `latest` → lockfile-only)
- **FileUpdater** — rewrites the manifest and regenerates the lockfile via `devbox update --no-install`

## Relationship to upstream

This gem tracks `dependabot-common ~> 0.383`. When dependabot-core cuts a new release, a patch version of this gem will update the pin. The implementation is kept in sync with the upstream PR.

## License

MIT
