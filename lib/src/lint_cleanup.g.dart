// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: lines_longer_than_80_chars

part of 'lint_cleanup.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

LintCleanupOptions _$parseLintCleanupOptionsResult(ArgResults result) =>
    LintCleanupOptions(
      packageDir: result['package-dir'] as String?,
      rewrite: result['rewrite'] as bool,
      help: result['help'] as bool,
    );

ArgParser _$populateLintCleanupOptionsParser(ArgParser parser) => parser
  ..addOption(
    'package-dir',
    abbr: 'p',
    help:
        'The directory to a package within the repository that depends\non the referenced include file. Needed for mono repos.',
  )
  ..addFlag(
    'rewrite',
    abbr: 'r',
    help:
        'Rewrites the analysis_options.yaml file to remove duplicative entries.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    help: 'Prints out usage and exits',
    negatable: false,
  );

final _$parserForLintCleanupOptions = _$populateLintCleanupOptionsParser(
  ArgParser(),
);

LintCleanupOptions parseLintCleanupOptions(List<String> args) {
  final result = _$parserForLintCleanupOptions.parse(args);
  return _$parseLintCleanupOptionsResult(result);
}
