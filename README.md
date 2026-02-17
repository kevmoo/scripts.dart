This repository contains various scripts and utilities for development.

## Summary

| Activated As | Script | Description |
|---|---|---|
| [`git-goma`](#git-goma) | `bin/git_clean.dart` | Clean up local git branches that have been merged or deleted on the remote. |
| [`lint-cleanup`](#lint-cleanup) | `bin/lint_cleanup.dart` | Clean up analysis_options.yaml files. |
| [`puppy`](#puppy) | `bin/puppy.dart` | Run a command in all package directories. |
| [`skill-link`](#skill-link) | `bin/skill_link.dart` | Manage agent skill symlinks. |
| [`tighten`](#tighten) | `bin/tighten.dart` | Tighten workspace dependencies. |

## Scripts

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

Reads a YAML configuration file (`~/.config/com.kevmoo.skills.yaml` by default)
that declares a list of `sources` and `targets`. It discovers agent skill
directories (folders containing a `SKILL.md` file nested inside specific `.agent`
or `_agent` folders) within the sources, and creates or maintains symlinks for
these skills inside the target directories.

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
