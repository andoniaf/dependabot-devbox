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

permissions:
  contents: write
  pull-requests: write
  issues: write  # creates the "dependencies" and "devbox" labels on the first run

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: andoniaf/dependabot-devbox@v0
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

That's it. No checkout step is needed: the action reads `devbox.json` and `devbox.lock` through the GitHub API. On each run it will:
1. Parse your `devbox.json`
2. Check Nixhub for newer versions of each package
3. Open a separate PR for every package that can be updated

A failure on one package (for example a resolution error) is logged and the remaining packages are still processed; the job then exits non-zero so the failure is visible.

Heads-up: PRs opened with the default `GITHUB_TOKEN` won't trigger your CI — see [Choosing a token](#choosing-a-token).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `github-token` | yes | — | Token used to open PRs (see [Choosing a token](#choosing-a-token)) — the default `GITHUB_TOKEN` works but won't trigger CI on the PRs |
| `directory` | no | `/` | Path to the directory containing `devbox.json` |
| `base-branch` | no | repo default | Branch to open PRs against |
| `gem-version` | no | version released with the action | `dependabot-devbox` gem version to install. A pinned action ref always runs the same gem; set to `latest` to track the newest published gem instead |
| `group-updates` | no | `false` | Group minor/patch updates into a single PR; each major update still gets its own PR. When `false`, every update (major or not) gets its own PR. |
| `cooldown-days` | no | `7` | Skip a package version until it has been released for this many days. Set to `0` to disable. |
| `exclude-packages` | no | — | Space/comma-separated package names to skip (e.g. `"go nodejs"`) |

### Choosing a token

With the default `secrets.GITHUB_TOKEN`, update PRs open fine but never trigger your `on: pull_request` workflows — the Checks tab stays empty and dependency bumps get no CI signal. These are two separate restrictions that are easy to conflate: the repo/org setting "Allow GitHub Actions to create and approve pull requests" only controls whether the PR can be *created*; GitHub deliberately never runs workflows on events caused by `GITHUB_TOKEN` (an anti-recursion rule with no opt-out). To get CI on the update PRs, pass a different token:

Whichever token you use, it needs **Contents: Read and write** and **Pull requests: Read and write**, plus **Issues: Read and write** so the `dependencies` and `devbox` labels can be created the first time (or create those two labels by hand and skip the Issues permission).

**Fine-grained PAT** — simplest for a single repo. Create a [fine-grained personal access token with the permissions pre-filled](https://github.com/settings/personal-access-tokens/new?name=dependabot-devbox&contents=write&pull_requests=write&issues=write), scope it to the target repo, store it as a secret, and pass it in:

```yaml
- uses: andoniaf/dependabot-devbox@v0
  with:
    github-token: ${{ secrets.DEVBOX_UPDATE_TOKEN }}
```

Trade-offs: tied to a user account, expires, and needs manual rotation.

**GitHub App token** — recommended, especially org-wide. Register a GitHub App with the permissions pre-filled — [on your personal account](https://github.com/settings/apps/new?name=devbox-updater&url=https://github.com/andoniaf/dependabot-devbox&contents=write&pull_requests=write&issues=write&webhook_active=false) or [in your organization](https://github.com/organizations/YOUR-ORG/settings/apps/new?name=devbox-updater&url=https://github.com/andoniaf/dependabot-devbox&contents=write&pull_requests=write&issues=write&webhook_active=false) (replace `YOUR-ORG`) — generate a private key, install the App on the repo, and store the App ID and private key as secrets. Then mint a short-lived token per run with [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token):

```yaml
steps:
  - uses: actions/create-github-app-token@v2
    id: app-token
    with:
      app-id: ${{ secrets.DEVBOX_APP_ID }}
      private-key: ${{ secrets.DEVBOX_APP_PRIVATE_KEY }}
  - uses: andoniaf/dependabot-devbox@v0
    with:
      github-token: ${{ steps.app-token.outputs.token }}
```

Not tied to a person, tokens auto-expire per run (no rotation), and PRs get a clean bot identity. The trade-off is more upfront setup.

Note: PRs opened with a PAT or App token are attributed to that user/bot, not `dependabot[bot]` — so workflow jobs gated on `github.actor != 'dependabot[bot]'` will run on these PRs.

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

Or run the bundled script directly. The [devbox CLI](https://www.jetify.com/devbox/docs/installing_devbox/) must be on `PATH`, since the lockfile is regenerated with `devbox update --no-install`:

```sh
GITHUB_REPOSITORY=owner/repo \
GITHUB_ACCESS_TOKEN=ghp_... \
dependabot-devbox-update
```

The script exits with `2` on a configuration error (missing token, invalid `COOLDOWN_DAYS`, devbox not installed) and `1` if any package failed to update; the other environment variables are `DIRECTORY_PATH`, `BASE_BRANCH`, `GROUP_UPDATES`, `COOLDOWN_DAYS` and `EXCLUDE_PACKAGES`.

## How it works

- **FileFetcher** — fetches `devbox.json` (and `devbox.lock` if present) from GitHub
- **FileParser** — parses `name@constraint` package entries (supports JSONC with comments/trailing commas)
- **UpdateChecker** — queries [Nixhub](https://search.devbox.sh) for available versions, respects constraint precision (`3.10` → minor-pinned, `3.10.15` → exact-pinned, `latest` → lockfile-only). nixpkgs date-style releases (`2025-04-04`) are treated as releases; snapshot builds (`unstable-…`) as pre-releases, so a package only moves to a snapshot when it already tracks one
- **FileUpdater** — rewrites the manifest and regenerates the lockfile via `devbox update --no-install`

## Relationship to upstream

This gem tracks `dependabot-common ~> 0.383`. When dependabot-core cuts a new release, a patch version of this gem will update the pin. The implementation is kept in sync with the upstream PR.

Releasing: bump the version in `dependabot-devbox.gemspec` and the `gem-version` default in `action.yml` together, then push a `vX.Y.Z` tag. The release workflow refuses a tag that does not match both, publishes the gem, creates the GitHub release and moves the floating major tag (`v0`) to it.

## License

MIT
