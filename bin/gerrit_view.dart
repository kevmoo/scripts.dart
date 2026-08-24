#!/usr/bin/env dart

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/gerrit_view.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'path-to-gerrit-repo',
      abbr: 'p',
      help: 'Path to a local gerrit repo. Defaults to CWD.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    setError(
      message: '${e.message}\n\n${parser.usage}',
      exitCode: ExitCode.usage.code,
    );
    return;
  }

  if (results['help'] as bool) {
    print('Complete overview of your active work on Gerrit.');
    print('');
    print('Usage: gerrit-view [options]');
    print(parser.usage);
    return;
  }

  final gerritRepo = results['path-to-gerrit-repo'] as String?;

  try {
    await runGerritView(gerritRepo: gerritRepo);
  } on GerritViewException catch (e, stack) {
    setError(message: e.message, exitCode: e.exitCode, stack: stack);
  } catch (e, stack) {
    setError(
      message: 'Unexpected error: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
