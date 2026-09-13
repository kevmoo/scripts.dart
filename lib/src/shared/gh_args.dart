import 'package:args/args.dart';

/// Appends common GitHub extraction arguments (`user`, `repo`, `limit`,
/// `last-n-days`, `json`, `markdown`, `help`).
void addCommonGhArgs(
  ArgParser parser, {
  required String itemType,
  String? userHelp,
  String lastNDaysAction = 'updated',
  String limitHelpSuffix = '',
}) {
  parser
    ..addOption(
      'user',
      abbr: 'u',
      defaultsTo: '@me',
      help: userHelp ?? 'The GitHub user to inspect.',
    )
    ..addOption(
      'repo',
      abbr: 'R',
      help: 'Filter $itemType to a specific repository (owner/repo).',
    )
    ..addOption(
      'limit',
      abbr: 'l',
      defaultsTo: '50',
      help: 'Maximum number of $itemType to retrieve$limitHelpSuffix.',
    )
    ..addOption(
      'last-n-days',
      abbr: 'd',
      aliases: const ['last-days', 'days'],
      help:
          'Filter $itemType $lastNDaysAction in the last N days '
          '(positive integer).',
    )
    ..addFlag('json', negatable: false, help: 'Output results in JSON format.')
    ..addFlag(
      'markdown',
      abbr: 'm',
      negatable: false,
      help: 'Output results as GitHub Flavored Markdown.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );
}
