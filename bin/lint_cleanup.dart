import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/lint_cleanup.dart';
import 'package:kevmoo_scripts/src/util.dart';

Future<void> main(List<String> arguments) async {
  final ArgResults argResults;

  try {
    argResults = _parser.parse(arguments);
  } on FormatException catch (e) {
    printError(e.message);
    print(_parser.usage);
    exitCode = ExitCode.usage.code;
    return;
  }

  if (argResults['help'] as bool) {
    print(_parser.usage);
    return;
  }

  final pkgDir = argResults['package-dir'] as String?;
  final rewrite = argResults['rewrite'] as bool;

  Directory pkgDirectory;
  if (pkgDir == null) {
    pkgDirectory = Directory.current;
  } else {
    pkgDirectory = Directory(pkgDir);
    if (!pkgDirectory.existsSync()) {
      print('Provided package-dir `$pkgDir` does not exist!');
      exitCode = 1;
      return;
    }
  }

  return runLintCleanup(packageDirectory: pkgDirectory, rewrite: rewrite);
}

final _parser = ArgParser()
  ..addOption(
    'package-dir',
    abbr: 'p',
    help:
        'The directory to a package within the repository that depends on the '
        'referenced include file. Needed for mono repos.',
  )
  ..addFlag(
    'rewrite',
    abbr: 'r',
    help:
        'Rewrites the analysis_options.yaml file to remove duplicative '
        'entries.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Prints out usage and exits',
  );
