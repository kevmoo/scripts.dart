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
| [`git-gm`](#git-gm) | `bin/git_gm.dart` | Safely switch to and update the default branch. |
| [`git-goma`](#git-goma) | `bin/git_clean.dart` | Clean up local git branches that have been merged or deleted on the remote. |
| [`lint-cleanup`](#lint-cleanup) | `bin/lint_cleanup.dart` | Clean up analysis_options.yaml files. |
| [`puppy`](#puppy) | `bin/puppy.dart` | Run a command in all package directories. |
| [`skill-link`](#skill-link) | `bin/skill_link.dart` | Manage agent skill symlinks. |
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

### `git-gm`
Safely switch to and update the default branch of a Git repository.

**Usage:**
```shell
git-gm [--verbose | -v] [--help | -h]
```

### `git-goma`
Clean up local git branches that have been merged or deleted on the remote.

**Usage:**
```shell
git-goma
```

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

### `skill-link`
Manages agent skill symlinks in a specified target directory.

Reads a YAML configuration file (`~/.config/skill-link.yaml` by default)
that declares a list of `sources` and `targets`. It discovers agent skill
directories (folders containing a `SKILL.md` file nested inside specific `.agent`
or `_agent` folders) within the sources, and creates or maintains symlinks for
these skills inside the target directories.

**Sample `skill-link.yaml`**

```yaml
sources:
  - /git/dart_skills
  - /git/team_skills
targets:
  - /Users/my_name/.gemini/agent-skills
```

**Usage:**
```shell
skill-link [options]

-c, --config    Path to the configuration file
-h, --help      Print this usage information.
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
