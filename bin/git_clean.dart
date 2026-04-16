import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_clean.dart';
import 'package:kevmoo_scripts/src/git_extensions.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    print(
      'Clean up local git branches that have been merged or deleted on '
      'the remote.',
    );
    print('');
    print('Usage: git_clean');
    return;
  }

  try {
    // 1. Validating we are in a git repo
    final gitDir = await GitDirExtensions.fromCurrentDirectory();
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
