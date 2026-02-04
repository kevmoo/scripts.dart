import 'package:git/git.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_clean.dart';
import 'package:kevmoo_scripts/src/util.dart';

void main(List<String> args) async {
  try {
    // 1. Validating we are in a git repo
    if (!await GitDir.isGitDir('.')) {
      throw GitCleanException('Not a git directory.');
    }

    final gitDir = await GitDir.fromExisting('.');
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
