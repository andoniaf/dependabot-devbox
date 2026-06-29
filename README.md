# dependabot-devbox

Automatically update [Devbox](https://www.jetify.com/devbox) package versions and open PRs — just like Dependabot, but for `devbox.json`.

This is a standalone implementation of devbox ecosystem support built on top of `dependabot-common`. It exists while [official support is pending](https://github.com/dependabot/dependabot-core/pull/14500) in upstream dependabot-core. When that PR merges, you can switch to the native Dependabot experience.

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
