// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: lines_longer_than_80_chars

part of 'git_org_clean.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

CleanArgs _$parseCleanArgsResult(ArgResults result) =>
    CleanArgs(org: result['org'] as String?, help: result['help'] as bool);

ArgParser _$populateCleanArgsParser(ArgParser parser) => parser
  ..addOption('org', abbr: 'o', help: 'The target GitHub organization.')
  ..addFlag(
    'help',
    abbr: 'h',
    help: 'Print this usage information.',
    negatable: false,
  );

final _$parserForCleanArgs = _$populateCleanArgsParser(ArgParser());

CleanArgs parseCleanArgs(List<String> args) {
  final result = _$parserForCleanArgs.parse(args);
  return _$parseCleanArgsResult(result);
}
