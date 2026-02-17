import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/lint_cleanup.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> arguments) async {
  final LintCleanupOptions options;

  try {
    options = parseLintCleanupOptions(arguments);
  } on UsageException catch (e) {
    setError(message: e.message, exitCode: ExitCode.usage.code);
    print(e.usage);
    return;
  }

  if (options.help) {
    print('Clean up analysis_options.yaml files.');
    print('');
    print('Usage: lint_cleanup [arguments]');
    print('');
    print('Options:');
    print(lintCleanupUsage);
    return;
  }

  final pkgDir = options.packageDir;
  final rewrite = options.rewrite;

  Directory pkgDirectory;
  if (pkgDir == null) {
    pkgDirectory = Directory.current;
  } else {
    pkgDirectory = Directory(pkgDir);
    if (!pkgDirectory.existsSync()) {
      setError(
        message: 'Provided package-dir `$pkgDir` does not exist!',
        exitCode: ExitCode.usage.code,
      );
      return;
    }
  }

  return lintCleanup(packageDirectory: pkgDirectory, rewrite: rewrite);
}
