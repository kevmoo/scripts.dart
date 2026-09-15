#!/usr/bin/env dart

import 'dart:io';

import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/gh_clean.dart';
import 'package:kevmoo_scripts/src/shared/gh_args.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> arguments) async {
  final parser = GhCleanOptions.createArgParser();
  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gh-clean',
    description:
        'Clean up local branches and worktrees for merged GitHub pull '
        'requests.',
  );
  if (results == null) return;

  final limitRaw = results['limit'] as String;
  final parsedLimit = int.tryParse(limitRaw);
  if (parsedLimit == null || parsedLimit <= 0) {
    setError(
      message:
          'Invalid value for --limit: "$limitRaw". '
          'Must be a positive integer.\n\n${parser.usage}',
      exitCode: ExitCode.usage.code,
    );
    return;
  }
  var limit = parsedLimit;
  if (limit > 100) {
    stderr.writeln(
      'Warning: --limit exceeds GitHub API ceiling of 100. Clamping to 100.',
    );
    limit = 100;
  }

  final lastNDaysResult = parseLastNDaysOption(results, parser);
  if (!lastNDaysResult.valid) return;

  final options = GhCleanOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: limit,
    lastNDays: lastNDaysResult.value,
    apply: results['apply'] as bool,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
    localRoot: results['local-root'] as String?,
    skipSync: results['skip-sync'] as bool,
    skipWorktrees: results['skip-worktrees'] as bool,
    skipRemoteBranches: results['skip-remote-branches'] as bool,
    includeOwned: results['include-owned'] as bool,
  );

  await runCliGuarded(
    () => runGhClean(options: options, onProgress: stderr.writeln),
  );
}
