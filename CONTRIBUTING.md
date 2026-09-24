# Contributing to Scripts

When creating or modifying CLI scripts in this repository, please adhere to the
following best practices:

## 1. Entrypoint & Dispatcher Structure (`bin/` and `lib/src/kscripts_runner.dart`)

Keep entrypoint files minimal and register subcommands in the unified `kscripts`
dispatcher (`lib/src/kscripts_runner.dart`):

- **DO NOT** put complex logic directly in `bin/` scripts or add extra entries
  to `pubspec.yaml` `executables:` (which must only contain `kscripts` so
  `dart install` compiles a single AOT binary).
- **DO** move CLI argument parsing (`ArgParser`) and core implementation logic
  into `lib/src/<script>.dart` (exposing a `run<Name>Cli(List<String> args)`
  function) and register the subcommand in `kscriptSubcommands`.
- **DO** keep `bin/<script>.dart` as a thin wrapper that delegates directly to
  `run<Name>Cli(arguments)`.

## 2. Executable Scripts

For thin `bin/` wrappers:

- Add `#!/usr/bin/env dart` as the first line.
- Ensure the file is executable (`chmod +x bin/my_script.dart`).

## 3. Process Termination

Properly handle process termination. Uncaught exceptions automatically result in
a non-zero exit code, but expected errors should be handled gracefully.

- **DO** use the `exitCode` setter to report failure and let `main` complete
  naturally. Use standard sysexits (like `64` for usage errors, `78` for
  configuration).
- **AVOID** calling `exit(code)` directly, as it prevents "pause on exit"
  debugging.
- **DO** wrap your top-level call in a `try...catch` block to handle unexpected
  exceptions and set `exitCode = 1`.

## 4. Testing

- Write tests for logic extracted to `lib/`.
- Use `package:test_descriptor` or `package:test_process` to mock file system
  layout or assert process output respectively. Each feature should be designed
  for testability in isolation.
- Use the `prints` matcher from `package:test` instead of `runZoned` to assert
  output from synchronous or asynchronous blocks.

See the [`dart-best-practices`][1] skill for more detailed code examples and
standard package recommendations.

[1]:
  https://github.com/kevmoo/dash_skills/blob/main/skills/dart-best-practices/SKILL.md

## 5. Documentation

- Make sure the subcommand is documented in [README.md](README.md) (verified by
  `test/readme_test.dart`).
- Format Markdown documents with `mdf`
  (`prettier@3.9.6 --prose-wrap always --print-width 80`).
  - For GitHub Alerts (`> [!NOTE]`, `> [!WARNING]`, etc.), always include an
    empty blockquote line (`>`) immediately after `> [!TYPE]` so Prettier does
    not collapse the alert onto one line.
