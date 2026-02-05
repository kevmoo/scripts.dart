import 'dart:io';

import 'package:git/git.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_clean.dart';
import 'package:kevmoo_scripts/src/util.dart';

void main(List<String> args) async {
  try {
    // 1. Validating we are in a git repo

    // TODO: all of this logic should be added to the git package
    ProcessResult result;
    try {
      result = await Process.run('git', [
        'rev-parse',
        '--show-toplevel',
      ], runInShell: true);
    } on ProcessException catch (e) {
      throw GitCleanException('Not a git directory: ${e.message}');
    }

    if (result.exitCode != 0) {
      throw GitCleanException('Not a git directory.');
    }

    final gitRoot = (result.stdout as String).trim();

    final gitDir = await GitDir.fromExisting(gitRoot);
    await clean(gitDir);
  } on GitCleanException catch (e) {
    setError(message: e, exitCode: ExitCode.usage.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
