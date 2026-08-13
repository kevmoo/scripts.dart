This repository contains various scripts and utilities for development.
I don't plan on publishing this as a package (at least not any time soon).

To activate these scripts globally, run:

```shell
dart pub global activate --source git https://github.com/kevmoo/scripts.dart
```

## Summary

| Activated As | Script | Description |
|---|---|---|
| [`dart-clean`](#dart-clean) | `bin/dart_clean.dart` | Find and kill orphaned Dart processes. |
| [`gerrit-view`](#gerrit-view) | `bin/gerrit_view.dart` | Complete overview of your active work on Gerrit. |
| [`gh-view`](#gh-view) | `bin/gh_view.dart` | Complete overview of your active pull requests on GitHub. |
| [`git-org-clean`](#git-org-clean) | `bin/git_org_clean.dart` | Analyze a GitHub organization for archive/delete candidates. |
| [`git-up`](#git-up) | `bin/git_up.dart` | Safely switch to and update the default branch. |
| [`lint-cleanup`](#lint-cleanup) | `bin/lint_cleanup.dart` | Clean up analysis_options.yaml files. |
| [`puppy`](#puppy) | `bin/puppy.dart` | Run a command in all package directories. |
| [`tighten`](#tighten) | `bin/tighten.dart` | Tighten workspace dependencies. |

## Scripts

### `dart-clean`
Find and kill orphaned Dart processes.

**Requirements:**
This tool is only supported on macOS and requires the `witr` command-line
utility to be installed and in your `PATH`.

**Usage:**
```shell
dart-clean

-f, --[no-]force    Force kill without confirmation.
-l, --[no-]list     Only list orphaned processes; do not kill.
-h, --help          Print this usage information.
```

### `gerrit-view`
Complete overview of your active work on Gerrit.

**Requirements:**
This tool requires the `gob-curl` command-line utility (e.g. `/usr/local/bin/gob-curl`) to be installed and authenticated in your `PATH`.

**Usage:**
```shell
gerrit-view [options]

-p, --path-to-gerrit-repo    Path to a local gerrit repo. Defaults to CWD.
-h, --help                   Print this usage information.
```

### `gh-view`
Complete overview of your active pull requests on GitHub.

**Requirements:**
This tool wraps the GitHub CLI (`gh`) and requires it to be installed and
authenticated in your `PATH`.

**Usage:**
```shell
gh-view [options]

-u, --user          The GitHub user to inspect. (defaults to "@me")
-R, --repo          Filter PRs to a specific repository (owner/repo).
-l, --limit         Maximum number of PRs to retrieve. (defaults to "50")
    --json          Output results in JSON format.
-m, --[no-]markdown Output results as GitHub Flavored Markdown.
    --[no-]local    Cross-reference local workspace checkouts and worktrees. (defaults to on)
    --local-root    Base directory for local Git repositories (defaults to ~/github).
-h, --help          Print this usage information.
```

### `git-org-clean`
Analyze a GitHub organization for archive/delete candidates.

**Requirements:**
This tool wraps the GitHub CLI (`gh`) and requires it to be installed and
authenticated in your `PATH`.

**Usage:**
```shell
git-org-clean [arguments]

-o, --org     The target GitHub organization.
-h, --help    Print this usage information.
```

### `git-up`
Safely switch to and update the default branch of a Git repository.

**Usage:**
```shell
git-up [--verbose | -v] [--help | -h]
```

**Pre-Update Hook (`git-up.before`):**

You can configure a custom shell command that runs automatically before `git-up` starts updating the repository (right after the dirty-tree safety check). This is useful for renewing credentials (e.g., running `gcert` on the Dart SDK) or preparing the environment.

* **Local configuration** (runs only for the current repository):
  ```shell
  git config git-up.before "gcert"
  ```

* **Global configuration** (runs for all repositories where you run `git-up`):
  ```shell
  git config --global git-up.before "gcert"
  ```

If the before-command returns a non-zero exit code, `git-up` will abort immediately and exit with that same exit code, preventing any branches from being updated.

**Post-Update Hook (`git-up.post`):**

You can configure a custom shell command that runs automatically after `git-up` successfully updates the repository. This is useful for triggering automated builds, running package installations (e.g., `dart pub get`), running code generation, or starting workspace bootstraps.

* **Local configuration** (runs only for the current repository):
  ```shell
  git config git-up.post "dart pub get"
  ```

* **Global configuration** (runs for all repositories where you run `git-up`):
  ```shell
  git config --global git-up.post "git status"
  ```

If the post-command returns a non-zero exit code, `git-up` will abort and exit with that same exit code.

### `lint-cleanup`
Clean up `analysis_options.yaml` files.

**Usage:**
```shell
lint-cleanup [arguments]

-p, --package-dir     The directory to a package within the repository that depends
                      on the referenced include file. Needed for mono repos.
-r, --[no-]rewrite    Rewrites the analysis_options.yaml file to remove duplicative entries.
-h, --help            Prints out usage and exits
```

### `puppy`
Run a command in all package directories.

**Usage:**
```shell
puppy [arguments] <command to invoke>

-d, --[no-]deep    Keep looking for "nested" pubspec files.
-h, --help         Print this usage information.
```

### `tighten`
Tighten workspace dependencies.

**Usage:**
```shell
tighten

-w, --workspace    Tighten workspace dependencies
-h, --help         Print this usage information.
```

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md) for best practices on writing and
maintaining scripts.
