This repository contains various scripts and utilities for development.

## Summary

| Script | Activated As | Description |
|---|---|---|
| `bin/git_clean.dart` | `git-goma` | Fetches, prunes, fast-forwards primary branch, and cleans up local branches. |
| `bin/lint_cleanup.dart` | `lint_cleanup` | Rewrites the `analysis_options.yaml` file to remove duplicative entries. |
| `bin/puppy.dart` | `puppy` | Executes a command across all nested packages in a repository. |
| `bin/skill_link.dart` | `skill_link` | Manages agent skill symlinks in a specified target directory. |
| `bin/tighten.dart` | `tighten` | Tightens package dependencies based on the oldest supported Dart SDK version. |
| `bin/who_listen.dart` | `who_listen` | Lists active listening server processes and associated ports. |

## Scripts

### `skill_link`
Manages agent skill symlinks in a specified target directory.

Reads a YAML configuration file (`~/.config/com.kevmoo.skills.yaml` by default)
that declares a list of `sources` and `targets`. It discovers agent skill
directories (folders containing a `SKILL.md` file nested inside specific `.agent`
or `_agent` folders) within the sources, and creates or maintains symlinks for
these skills inside the target directories.

**Usage:**
```shell
dart run bin/skill_link.dart [options]

-c, --config    Path to the configuration file
-h, --help      Print this usage information.
```

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md) for best practices on writing and
maintaining scripts.
