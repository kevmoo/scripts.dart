#!/usr/bin/env dart

import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/gh_issues.dart';
import 'package:kevmoo_scripts/src/shared/gh_args.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> arguments) async {
  final parser = GhIssuesOptions.createArgParser();
  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gh-issues',
    description: 'Complete overview of your open assigned issues on GitHub.',
  );
  if (results == null) return;

  final lastNDaysResult = parseLastNDaysOption(results, parser);
  if (!lastNDaysResult.valid) return;

  int? createdDays;
  final createdDaysRaw = results['created-days'] as String?;
  if (createdDaysRaw != null) {
    final parsed = int.tryParse(createdDaysRaw);
    if (parsed == null || parsed < 0) {
      setError(
        message:
            'Invalid value for --created-days: "$createdDaysRaw". '
            'Must be a non-negative integer (0 for no limit).\n\n'
            '${parser.usage}',
        exitCode: ExitCode.usage.code,
      );
      return;
    }
    createdDays = parsed > 0 ? parsed : 0;
  }

  final options = GhIssuesOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: int.tryParse(results['limit'] as String) ?? 50,
    lastNDays: lastNDaysResult.value,
    createdDays: createdDays,
    checkLinkedPrs: results['linked-prs'] as bool,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
  );

  await runCliGuarded(() => runGhIssues(options: options));
}
