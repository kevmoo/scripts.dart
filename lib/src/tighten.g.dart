// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: lines_longer_than_80_chars

part of 'tighten.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

TightenOptions _$parseTightenOptionsResult(ArgResults result) => TightenOptions(
  workspace: result['workspace'] as bool,
  help: result['help'] as bool,
);

ArgParser _$populateTightenOptionsParser(ArgParser parser) => parser
  ..addFlag(
    'workspace',
    abbr: 'w',
    help: 'Tighten workspace dependencies',
    negatable: false,
  )
  ..addFlag(
    'help',
    abbr: 'h',
    help: 'Print this usage information.',
    negatable: false,
  );

final _$parserForTightenOptions = _$populateTightenOptionsParser(ArgParser());

TightenOptions parseTightenOptions(List<String> args) {
  final result = _$parserForTightenOptions.parse(args);
  return _$parseTightenOptionsResult(result);
}
