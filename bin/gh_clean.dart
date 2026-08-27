#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/gh_clean.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> arguments) async {
  final parser = GhCleanOptions.createArgParser();

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
    print(
      'Clean up local branches and worktrees for merged GitHub pull requests.',
    );
    print('');
    print('Usage: gh-clean [options]');
    print(parser.usage);
    return;
  }

  final limit = int.tryParse(results['limit'] as String) ?? 50;

  int? lastNDays;
  final lastNDaysRaw = results['last-n-days'] as String?;
  if (lastNDaysRaw != null) {
    final parsed = int.tryParse(lastNDaysRaw);
    if (parsed == null || parsed < 0) {
      setError(
        message:
            'Invalid value for --last-n-days: "$lastNDaysRaw". '
            'Must be a non-negative integer.\n\n${parser.usage}',
        exitCode: ExitCode.usage.code,
      );
      return;
    }
    if (parsed > 0) {
      lastNDays = parsed;
    }
  }

  final options = GhCleanOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: limit,
    lastNDays: lastNDays,
    apply: results['apply'] as bool,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
    localRoot: results['local-root'] as String?,
    skipSync: results['skip-sync'] as bool,
    skipWorktrees: results['skip-worktrees'] as bool,
    includeOwned: results['include-owned'] as bool,
  );

  try {
    await runGhClean(options: options);
  } on GhCleanException catch (e, stack) {
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
