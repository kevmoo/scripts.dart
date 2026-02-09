// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'puppy.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

RunArgs _$parseRunArgsResult(ArgResults result) =>
    RunArgs(deep: result['deep'] as bool, rest: result.rest);

ArgParser _$populateRunArgsParser(ArgParser parser) => parser
  ..addFlag(
    'deep',
    abbr: 'd',
    help: 'Keep looking for "nested" pubspec files.',
  );

final _$parserForRunArgs = _$populateRunArgsParser(ArgParser());

RunArgs parseRunArgs(List<String> args) {
  final result = _$parserForRunArgs.parse(args);
  return _$parseRunArgsResult(result);
}
