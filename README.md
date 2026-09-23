This repository contains various scripts and utilities for development. I don't
plan on publishing this as a package (at least not any time soon).

To install these scripts as native AOT executables, run:

```shell
dart install 'kevmoo_scripts@{git: https://github.com/kevmoo/scripts.dart}'
```

Or for local development:

```shell
dart install 'kevmoo_scripts@{path: /path/to/scripts.dart}'
```

This installs a single AOT binary, `kscripts`; everything else is a subcommand
(`kscripts gh-view`, `kscripts git-up`, …).

To keep a bare command name on your `PATH`, symlink it to `kscripts` or set
`KSCRIPTS_AS` — both dispatch to the matching subcommand:

```shell
ln -s "$(command -v kscripts)" ~/.local/bin/gh-view   # gh-view --json
KSCRIPTS_AS=git-up kscripts --check                   # same as: kscripts git-up --check
```

If `KSCRIPTS_AS` names a subcommand this build does not have, `kscripts` exits
78 and tells you to reinstall: it means a `_kscripts_shim` symlink from a newer
dotfiles sync outran the installed binary.

For a `path:` install, `kscripts` warns when the binary is older than the
checkout's `main` ref. For a `git:` install, set `KSCRIPTS_REPO_DIR` to a local
`scripts.dart` checkout to enable the same check.

## Summary

| Subcommand                        | Script                   | Description                                                            |
| --------------------------------- | ------------------------ | ---------------------------------------------------------------------- |
| [`dart-clean`](#dart-clean)       | `bin/dart_clean.dart`    | Find and kill orphaned Dart processes.                                 |
| [`gerrit-view`](#gerrit-view)     | `bin/gerrit_view.dart`   | Complete overview of your active work on Gerrit.                       |
| [`gh-clean`](#gh-clean)           | `bin/gh_clean.dart`      | Clean up local branches and worktrees for merged GitHub pull requests. |
| [`gh-issues`](#gh-issues)         | `bin/gh_issues.dart`     | Complete overview of your open assigned issues on GitHub.              |
| [`gh-view`](#gh-view)             | `bin/gh_view.dart`       | Complete overview of your active pull requests on GitHub.              |
| [`git-org-clean`](#git-org-clean) | `bin/git_org_clean.dart` | Analyze a GitHub organization for archive/delete candidates.           |
| [`git-up`](#git-up)               | `bin/git_up.dart`        | Safely switch to and update the default branch.                        |
| [`kscripts`](#kscripts)           | `bin/kscripts.dart`      | Unified CLI runner for kevmoo_scripts developer utilities.             |
| [`lint-cleanup`](#lint-cleanup)   | `bin/lint_cleanup.dart`  | Clean up analysis_options.yaml files.                                  |
| [`pr-check`](#pr-check)           | `bin/pr_check.dart`      | Validate local CI parity before running gh pr create.                  |
| [`puppy`](#puppy)                 | `bin/puppy.dart`         | Run a command in all package directories.                              |
| [`relay-whoami`](#relay-whoami)   | `bin/relay_whoami.dart`  | Cross-machine agent relay identity, envelope, and sync status checker. |
| [`repo-align`](#repo-align)       | `bin/repo_align.dart`    | Personal GitHub Repositories Alignment & Audit Tool                    |
| [`tighten`](#tighten)             | `bin/tighten.dart`       | Tighten workspace dependencies.                                        |

## Agent Skills (`skills/`)

Co-located agent skills that orchestrate `kscripts` subcommands:

- [`skills/pr-cleanup`](skills/pr-cleanup/SKILL.md): Multi-repo GitHub PR,
  Gerrit CL, and local Git worktree/branch cleanup sweep (`kscripts gh-clean`,
  `kscripts gh-view`, `kscripts gerrit-view`, `kscripts gh-issues`).
- [`skills/repo-align`](skills/repo-align/SKILL.md): Personal GitHub repository
  CI workflow, markdown, lint, and branch ruleset alignment
  (`kscripts repo-align`, `kscripts lint-cleanup`, `kscripts tighten`).

## Scripts

### `dart-clean`

Find and kill orphaned Dart processes.

**Requirements:** Supported on macOS (requires the `witr` command-line utility
in your `PATH`) and Linux (reads `/proc` directly with systemd subreaper
detection).

**Usage:**

```shell
kscripts dart-clean

-f, --[no-]force    Force kill without confirmation.
-l, --[no-]list     Only list orphaned processes; do not kill.
-h, --help          Print this usage information.
```

### `gerrit-view`

Complete overview of your active work on Gerrit.

**Requirements:** This tool requires the `gob-curl` command-line utility (e.g.
`/usr/local/bin/gob-curl`) to be installed and authenticated in your `PATH`.

**Usage:**

```shell
kscripts gerrit-view [options]

-p, --path-to-gerrit-repo    Path to a local gerrit repo. Defaults to CWD.
-h, --help                   Print this usage information.
```

### `gh-clean`

Clean up local branches and worktrees for merged GitHub pull requests.

**Requirements:** This tool wraps the GitHub CLI (`gh`) and requires it to be
installed and authenticated in your `PATH`.

**Usage:**

```shell
kscripts gh-clean [options]

-u, --user               The GitHub user to inspect. (defaults to "@me")
-R, --repo               Filter PRs to a specific repository (owner/repo).
-l, --limit              Maximum number of PRs to retrieve (capped at 100). (defaults to "50")
-d, --last-n-days        Filter PRs merged in the last N days (positive integer). (defaults to "7")
    --apply              Execute worktree pruning, branch deletion, and trunk sync.
    --json               Output results in JSON format.
-m, --[no-]markdown      Output results as GitHub Flavored Markdown.
    --local-root         Base directory for local Git repositories (defaults to ~/github).
    --[no-]skip-sync     Skip fast-forwarding default branches against origin.
    --[no-]skip-worktrees Skip pruning matching sibling worktrees.
    --[no-]include-owned Include repositories owned by the user. (defaults to on)
-h, --help               Print this usage information.
```

### `gh-issues`

Complete overview of your open assigned issues on GitHub.

**Requirements:** This tool wraps the GitHub CLI (`gh`) and requires it to be
installed and authenticated in your `PATH`.

**Usage:**

```shell
kscripts gh-issues [options]

-u, --user               The GitHub user assigned to the issues.
                         (defaults to "@me")
-R, --repo               Filter issues to a specific repository (owner/repo).
-l, --limit              Maximum number of issues to retrieve.
                         (defaults to "50")
-d, --last-n-days        Filter issues updated in the last N days (positive integer).
-c, --created-days       Filter issues created in the last N days (positive integer, 0 for no limit).
                         (defaults to "365")
    --[no-]linked-prs    Cross-reference linked Pull Requests.
                         (defaults to on)
    --json               Output results in JSON format.
-m, --[no-]markdown      Output results as GitHub Flavored Markdown.
-h, --help               Print this usage information.
```

### `gh-view`

Complete overview of your active pull requests on GitHub.

**Requirements:** This tool wraps the GitHub CLI (`gh`) and requires it to be
installed and authenticated in your `PATH`.

**Usage:**

```shell
kscripts gh-view [options]

-u, --user           The GitHub user to inspect. (defaults to "@me")
-R, --repo           Filter PRs to a specific repository (owner/repo).
-l, --limit          Maximum number of PRs to retrieve. (defaults to "50")
-d, --last-n-days    Filter PRs touched in the last N days (positive integer).
    --json           Output results in JSON format.
-m, --[no-]markdown  Output results as GitHub Flavored Markdown.
    --[no-]local     Cross-reference local workspace checkouts and worktrees. (defaults to on)
    --local-root     Base directory for local Git repositories (defaults to ~/github).
-e, --enricher       External command or script to enrich PRs with project/context metadata.
-h, --help           Print this usage information.
```

### `git-org-clean`

Analyze a GitHub organization for archive/delete candidates.

**Requirements:** This tool wraps the GitHub CLI (`gh`) and requires it to be
installed and authenticated in your `PATH`.

**Usage:**

```shell
kscripts git-org-clean [arguments]

-o, --org     The target GitHub organization.
-h, --help    Print this usage information.
```

### `git-up`

Safely switch to and update the default branch of a Git repository.

**Usage:**

```shell
kscripts git-up [--verbose | -v] [--help | -h]
```

**Pre-Update Hook (`git-up.before`):**

You can configure a custom shell command that runs automatically before `git-up`
starts updating the repository (right after the dirty-tree safety check). This
is useful for renewing credentials (e.g., running `gcert` on the Dart SDK) or
preparing the environment.

- **Local configuration** (runs only for the current repository):

  ```shell
  git config git-up.before "gcert"
  ```

- **Global configuration** (runs for all repositories where you run `git-up`):
  ```shell
  git config --global git-up.before "gcert"
  ```

If the before-command returns a non-zero exit code, `git-up` will abort
immediately and exit with that same exit code, preventing any branches from
being updated.

**Post-Update Hook (`git-up.post`):**

You can configure a custom shell command that runs automatically after `git-up`
successfully updates the repository. This is useful for triggering automated
builds, running package installations (e.g., `dart pub get`), running code
generation, or starting workspace bootstraps.

- **Local configuration** (runs only for the current repository):

  ```shell
  git config git-up.post "dart pub get"
  ```

- **Global configuration** (runs for all repositories where you run `git-up`):
  ```shell
  git config --global git-up.post "git status"
  ```

If the post-command returns a non-zero exit code, `git-up` will abort and exit
with that same exit code.

### `kscripts`

Unified CLI runner for `kevmoo_scripts` developer utilities.

**Usage:**

```shell
kscripts <subcommand> [arguments]
```

### `lint-cleanup`

Clean up `analysis_options.yaml` files.

**Usage:**

```shell
kscripts lint-cleanup [arguments]

-p, --package-dir     The directory to a package within the repository that depends
                      on the referenced include file. Needed for mono repos.
-r, --[no-]rewrite    Rewrites the analysis_options.yaml file to remove duplicative entries.
-h, --help            Prints out usage and exits
```

### `pr-check`

Validate local CI parity before running `gh pr create`.

**Usage:**

```shell
kscripts pr-check [options]

-d, --dir                 Repository or worktree directory to validate.
                          (defaults to ".")
-b, --base                Base git ref to diff against (defaults to origin/HEAD or main).
    --[no-]require-wip    Require touched publishable packages at a released version to bump to a -wip version.
                          (defaults to on)
-h, --help                Print this usage information.
```

### `puppy`

Run a command in all package directories.

**Usage:**

```shell
kscripts puppy [arguments] <command to invoke>

-d, --[no-]deep    Keep looking for "nested" pubspec files.
-h, --help         Print this usage information.
```

### `relay-whoami`

Cross-machine agent relay identity, envelope, and sync status checker.

**Usage:**

```shell
kscripts relay-whoami [--check | --header] [options]
```

### `repo-align`

Personal GitHub Repositories Alignment & Audit Tool

**Requirements:** This tool wraps the GitHub CLI (`gh`) and requires it to be
installed and authenticated in your `PATH`.

**Usage:**

```shell
kscripts repo-align <check|fix> [options]

-r, --repo            Target a specific repository by name (e.g. stats, pubviz)
    --json            Output check results in JSON format
    --[no-]lints      Fix/synchronize analysis_options.yaml
    --[no-]ci         Fix/synchronize CI workflows (lower_bound, complexity, autosubmit, dependabot)
    --[no-]github     Fix/synchronize GitHub remote settings (auto-merge, rulesets)
-n, --[no-]dry-run    Preview changes without modifying files or remote settings
-h, --help            Show command usage
```

### `tighten`

Tighten workspace dependencies.

**Usage:**

```shell
kscripts tighten

-w, --workspace    Tighten workspace dependencies
-h, --help         Print this usage information.
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for best practices on writing and
maintaining scripts.
