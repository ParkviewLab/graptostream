# Contributing

The authoritative, org-wide version of all of this is the [ParkviewLab handbook](https://github.com/ParkviewLab/handbook/tree/main).

This repo follows the ParkviewLab conventions. The essentials:

## Branch & PR flow

- Branch off `develop` into an ephemeral worktree named with a prefix: `feature-`, `bug-`/`fix-`, `doc-`, `test-`, `ops-`, `ci-`, `build-`, `release-` (hyphen, not slash). See the handbook's `branching.md`.
- Open a PR into `develop`. The repo is merge-commit only, so the merge button can only make a merge commit; merging is the maintainer's action.
- Releases are cut from `main` via the CLI (`git merge --no-ff develop`, then bump + tag), not a PR, and end with the back-merge pull request from `back-merge-<tag>`, which `git back-merge` opens, checks and merges. See the handbook's `releases.md`.

## Commit / PR-title convention (this is what the changelog reads)

Because a PR is merged with a merge commit titled `<PR title> (#N)`, the PR title becomes the commit subject, and the changelog is generated from it. Prefix every PR title with a [Conventional Commit](https://www.conventionalcommits.org/) type (`feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `build:`, `chore:`, `ci:`, `style:`; `!` after the type for a breaking change). A `BREAKING CHANGE:` footer belongs in the PR's description. See the handbook's `commits-and-changelogs.md`.

## Local checks before opening a PR

Run the same checks CI requires, so the PR is green on arrival:

```bash
swift build
swift test
uvx --from "reuse[charset-normalizer]" reuse lint
```

The package needs Xcode with the macOS 26 SDK or later. The version lives in `VERSION.txt`; a feature PR never changes it (the `no-version-change` check), since the bump happens at release.
