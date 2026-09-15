#!/usr/bin/env dart

import 'package:kevmoo_scripts/src/dart_clean.dart';
import 'package:kevmoo_scripts/src/shared/gh_args.dart';

Future<void> main(List<String> args) async {
  await runCliGuarded(() async {
    final options = parseDartCleanOptions(args);

    if (options.help) {
      print('Find and kill orphaned Dart processes.');
      print('');
      print(dartCleanOptionsUsage);
      return;
    }

    await runDartClean(options);
  }, usageForFormatException: dartCleanOptionsUsage);
}
