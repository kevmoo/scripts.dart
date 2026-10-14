import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:io/io.dart';

import '../testable_print.dart';

/// Base exception for CLI tools that carry a message and process exit code.
class CliException implements Exception {
  final String message;
  final int exitCode;

  const new(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}

/// Parses [arguments] with [parser], handling `--help` and [FormatException].
///
/// Returns `null` if `--help` was printed or argument parsing failed.
ArgResults? parseCliArgs(
  ArgParser parser,
  List<String> arguments, {
  required String commandName,
  required String description,
}) {
  ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    setError(
      message: '${e.message}\n\n${parser.usage}',
      exitCode: ExitCode.usage.code,
    );
    return null;
  }

  if (results['help'] as bool) {
    print(description);
    print('');
    print('Usage: $commandName [options]');
    print(parser.usage);
    return null;
  }

  return results;
}

/// Parses and validates `--last-n-days` as a positive integer.
///
/// Returns `(value: null, valid: false)` and calls [setError] if the value is
/// invalid.
({int? value, bool valid}) parseLastNDaysOption(
  ArgResults results,
  ArgParser parser,
) {
  final lastNDaysRaw = results['last-n-days'] as String?;
  if (lastNDaysRaw == null) return (value: null, valid: true);
  final parsed = int.tryParse(lastNDaysRaw);
  if (parsed == null || parsed <= 0) {
    setError(
      message:
          'Invalid value for --last-n-days: "$lastNDaysRaw". '
          'Must be a positive integer.\n\n${parser.usage}',
      exitCode: ExitCode.usage.code,
    );
    return (value: null, valid: false);
  }
  return (value: parsed, valid: true);
}

/// Parses the `--repo` (`-R`) multi-option into a comma-separated string, or
/// `null` if no repositories were specified.
String? parseRepoOption(ArgResults results) {
  final raw = results['repo'];
  if (raw is List<String>) {
    final trimmed = [
      for (final part in raw)
        if (part.trim() case final t when t.isNotEmpty) t,
    ];
    return trimmed.isEmpty ? null : trimmed.join(',');
  }
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

/// Splits a single or comma-separated [repo] filter into normalized
/// `owner/repo` tokens.
List<String> splitRepoFilter(String? repo) {
  if (repo == null || repo.trim().isEmpty) return const [];
  return [
    for (final part in repo.split(','))
      if (part.trim() case final t when t.isNotEmpty) t,
  ];
}

/// Appends one or more ` repo:<owner/repo>` qualifiers to [buffer] from [repo].
void writeRepoSearchQualifiers(StringBuffer buffer, String? repo) {
  for (final r in splitRepoFilter(repo)) {
    buffer.write(' repo:$r');
  }
}

/// Executes [action] and catches common CLI exceptions ([FormatException],
/// [UsageException], [CliException], [ProcessException], and unexpected
/// errors).
Future<void> runCliGuarded(
  Future<void> Function() action, {
  String? usageForFormatException,
}) async {
  try {
    await action();
  } on FormatException catch (e, stack) {
    setError(
      message: usageForFormatException != null
          ? '${e.message}\n\n$usageForFormatException'
          : e.message,
      exitCode: ExitCode.usage.code,
      stack: stack,
    );
  } on UsageException catch (e) {
    setError(message: e.message, exitCode: ExitCode.usage.code);
  } on CliException catch (e, stack) {
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
    ..addMultiOption(
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
