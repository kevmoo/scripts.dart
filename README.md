This repository contains various scripts and utilities for development.

## Summary

| Activated As | Script | Description |
|---|---|---|
| `git-goma` | `bin/git_clean.dart` | Clean up local git branches that have been merged or deleted on the remote. |
| `lint-cleanup` | `bin/lint_cleanup.dart` | Clean up analysis_options.yaml files. |
| `puppy` | `bin/puppy.dart` | Run a command in all package directories. |
| `skill-link` | `bin/skill_link.dart` | Manage agent skill symlinks. |
| `tighten` | `bin/tighten.dart` | Tighten workspace dependencies. |

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
