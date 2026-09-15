#!/usr/bin/env dart

import 'package:kevmoo_scripts/src/gh_view.dart';
import 'package:kevmoo_scripts/src/shared/gh_args.dart';

Future<void> main(List<String> arguments) async {
  final parser = GhViewOptions.createArgParser();
  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gh-view',
    description: 'Complete overview of your active pull requests on GitHub.',
  );
  if (results == null) return;

  final lastNDaysResult = parseLastNDaysOption(results, parser);
  if (!lastNDaysResult.valid) return;

  final options = GhViewOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: int.tryParse(results['limit'] as String) ?? 50,
    lastNDays: lastNDaysResult.value,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
    checkLocal: results['local'] as bool,
    localRoot: results['local-root'] as String?,
    enricher: results['enricher'] as String?,
  );

  await runCliGuarded(() => runGhView(options: options));
}
