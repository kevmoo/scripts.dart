import 'dart:io';

import 'package:git/git.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_clean.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

void main(List<String> args) async {
  try {
    // 1. Validating we are in a git repo

    // TODO: all of this logic should be added to the git package
    ProcessResult result;
    try {
      result = await Process.run('git', ['rev-parse', '--show-toplevel']);
    } on ProcessException catch (e, stack) {
      setError(
        message:
            'Failed to run git. Is it installed and in your PATH? '
            'Error: ${e.message}',
        exitCode: ExitCode.software.code,
        stack: stack,
      );
      return;
    }

    if (result.exitCode != 0) {
      setError(message: result.stderr.toString(), exitCode: result.exitCode);
      return;
    }

    final gitRoot = (result.stdout as String).trim();

    final gitDir = await GitDir.fromExisting(gitRoot);
    await gitClean(gitDir);
  } on GitCleanException catch (e) {
    setError(message: e, exitCode: ExitCode.usage.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: ${e.toString().trim()}',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
