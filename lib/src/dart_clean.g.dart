// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: lines_longer_than_80_chars

part of 'dart_clean.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

DartCleanOptions _$parseDartCleanOptionsResult(ArgResults result) =>
    DartCleanOptions(
      force: result['force'] as bool,
      list: result['list'] as bool,
      help: result['help'] as bool,
    );

ArgParser _$populateDartCleanOptionsParser(ArgParser parser) => parser
  ..addFlag('force', abbr: 'f', help: 'Force kill without confirmation.')
  ..addFlag(
    'list',
    abbr: 'l',
    help: 'Only list orphaned processes; do not kill.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    help: 'Print this usage information.',
    negatable: false,
  );

final _$parserForDartCleanOptions = _$populateDartCleanOptionsParser(
  ArgParser(),
);

DartCleanOptions parseDartCleanOptions(List<String> args) {
  final result = _$parserForDartCleanOptions.parse(args);
  return _$parseDartCleanOptionsResult(result);
}
