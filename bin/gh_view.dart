#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/gh_view.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> arguments) async {
  final parser = GhViewOptions.createArgParser();

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    setError(message: e.message, exitCode: ExitCode.usage.code);
    print(parser.usage);
    return;
  }

  if (results['help'] as bool) {
    print('Complete overview of your active pull requests on GitHub.');
    print('');
    print('Usage: gh-view [options]');
    print(parser.usage);
    return;
  }

  final limit = int.tryParse(results['limit'] as String) ?? 50;
  final options = GhViewOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: limit,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
    checkLocal: results['local'] as bool,
    localRoot: results['local-root'] as String?,
  );

  try {
    await runGhView(options: options);
  } on GhViewException catch (e, stack) {
    setError(message: e.message, exitCode: e.exitCode, stack: stack);
  } on ProcessException catch (e, stack) {
    setError(message: 'Process error: ${e.message}', exitCode: 1, stack: stack);
  } catch (e, stack) {
    setError(
      message: 'Unexpected error: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
