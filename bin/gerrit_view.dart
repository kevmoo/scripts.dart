#!/usr/bin/env dart

import 'package:args/args.dart';
import 'package:kevmoo_scripts/src/gerrit_view.dart';
import 'package:kevmoo_scripts/src/shared/gh_args.dart';

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

  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gerrit-view',
    description: 'Complete overview of your active work on Gerrit.',
  );
  if (results == null) return;

  final gerritRepo = results['path-to-gerrit-repo'] as String?;
  await runCliGuarded(() => runGerritView(gerritRepo: gerritRepo));
}
