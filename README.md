# mbl-actionhub-bump-version

Composite GitHub Action — opens a PR bumping a version key in a properties file after a successful release. Optionally enables auto-merge.

Companion to [`mbl-actionhub-resolve-version`](https://github.com/MobileByteLabs/mbl-actionhub-resolve-version): the resolver reads the committed value before publishing; this action bumps the committed value after publishing so the next cycle has a valid sanity-check target.

## What it does

1. Computes `next-version` from `published-version` + `bump-type`.
2. Edits `properties-key` in `properties-path` to the new value.
3. Creates branch `{branch-prefix}-{next-version}`.
4. Commits + pushes.
5. Opens a PR against `base-branch`.
6. (Optional) Enables auto-merge `--squash` on the PR.
7. Skips cleanly if the bump branch already exists (re-run safe).

## Quick example

```yaml
- uses: actions/checkout@v6
  with:
    ref: ${{ github.ref }}
    fetch-depth: 0
- uses: MobileByteLabs/mbl-actionhub-bump-version@v1.0.0
  with:
    published-version: '3.2.3'
    properties-key: 'kmptoolkit.version'
    bump-type: 'patch'
```

After publishing v3.2.3, this opens a PR setting `kmptoolkit.version=3.2.4` in `gradle.properties` and enables auto-merge.

## Inputs

| Input | Required | Default | Description |
|---|:---:|---|---|
| `published-version` | **Yes** | — | Version that was just published (e.g. `3.2.3`) |
| `properties-key` | **Yes** | — | Key to update (e.g. `kmptoolkit.version`) |
| `properties-path` | No | `gradle.properties` | Path to file |
| `bump-type` | No | `patch` | `patch` / `minor` / `major` |
| `base-branch` | No | `${{ github.ref_name }}` | Target branch for the PR |
| `branch-prefix` | No | `chore/bump-version` | Branch name prefix |
| `pr-title` | No | `chore(version): bump {key} to {next} (post-release)` | Title; supports `{key}`, `{next}`, `{published}` |
| `auto-merge` | No | `true` | Enable auto-merge `--squash` on PR (best-effort) |
| `delete-branch-on-merge` | No | `true` | Pass `--delete-branch` to `gh pr merge` |
| `github-token` | No | `${{ github.token }}` | Token for git push + gh pr ops |
| `git-user-name` / `git-user-email` | No | `github-actions[bot]` defaults | Commit author identity |

## Outputs

| Output | Description |
|---|---|
| `next-version` | Computed next version |
| `pr-url` | URL of the opened PR (empty if skipped) |
| `pr-number` | PR number (empty if skipped) |
| `branch` | Bump branch name |
| `skipped` | `true` if the bump was skipped (branch already existed) |

## When auto-merge needs an explicit PAT

If your `base-branch` requires PR review approvals or status checks **and** uses the default `GITHUB_TOKEN`, GitHub blocks pushes/PRs that match those rules from triggering downstream workflows. To make the PR's CI run normally, pass a PAT or app token via `github-token`.

```yaml
- uses: MobileByteLabs/mbl-actionhub-bump-version@v1.0.0
  with:
    published-version: ${{ needs.publish.outputs.version }}
    properties-key: 'kmptoolkit.version'
    github-token: ${{ secrets.RELEASE_BOT_TOKEN }}    # PAT with repo + workflow scopes
```

## Behavior on re-runs

If the workflow is re-run after a successful release, the bump branch from the original run will already exist. This action detects that and exits early with `skipped=true` — no duplicate PR, no force-push.

## Failure modes

- Invalid `published-version` (not semver `X.Y.Z`) → fails before any changes.
- Properties key not found in file → fails before any changes.
- Push fails (auth, branch protection) → fails after edit but before PR creation. Caller can retry.
- Auto-merge can't be enabled (repo setting / branch protection) → warning only; PR stays open.

## Testing

`tests/run-tests.sh` covers computation, output writing, error paths, and PR title substitution. Uses `BUMP_DRY_RUN=true` to short-circuit before any network operations.

```bash
bash tests/run-tests.sh
```

CI runs the suite on every PR via `.github/workflows/test.yml`.
