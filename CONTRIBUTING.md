# Contributing to Scripts

When creating or modifying CLI scripts in this repository, please adhere to the following best practices:

## 1. Entrypoint Structure (`bin/`)
Keep the contents of your entrypoint file minimal to decouple logic from the
process runner and improve testability.
- **DO NOT** put complex logic directly in `bin/` scripts.
- **DO** handle argument parsing (`ArgParser`) directly in `bin/` scripts.
- **DO** move core implementation logic to `lib/` and call it from `bin/`,
  passing only the parsed configuration/options to the `lib/` function.

## 2. Executable Scripts
For CLI tools intended to run directly:
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

See the [dart-cli-app-best-practices][1] skill for more detailed code examples
and standard package recommendations.

[1]: https://github.com/kevmoo/dash_skills/blob/main/.agent/skills/dart-cli-app-best-practices/SKILL.md

## 5. Documentation
- Make sure the script is documented in the [README.md](README.md).
- When modifying any markdown document, try to keep line lengths to 80.
  - Tables are an exception to this rule.
