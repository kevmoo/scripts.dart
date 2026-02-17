// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: lines_longer_than_80_chars

part of 'skill_link_runner.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

SkillLinkOptions _$parseSkillLinkOptionsResult(ArgResults result) =>
    SkillLinkOptions(
      config: result['config'] as String?,
      help: result['help'] as bool,
    );

ArgParser _$populateSkillLinkOptionsParser(ArgParser parser) => parser
  ..addOption(
    'config',
    abbr: 'c',
    help:
        'Path to the configuration file.\nDefaults to `\$HOME/.config/com.kevmoo.skills.yaml`',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    help: 'Print this usage information.',
    negatable: false,
  );

final _$parserForSkillLinkOptions = _$populateSkillLinkOptionsParser(
  ArgParser(),
);

SkillLinkOptions parseSkillLinkOptions(List<String> args) {
  final result = _$parserForSkillLinkOptions.parse(args);
  return _$parseSkillLinkOptionsResult(result);
}
