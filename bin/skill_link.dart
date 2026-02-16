#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/skill_link_runner.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      help:
          'Path to the configuration file.\n'
          'Defaults to $documentedConfigLocation',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  final ArgResults argResults;
  try {
    argResults = parser.parse(arguments);
  } on FormatException catch (e) {
    print(e.message);
    print('');
    print(parser.usage);
    exitCode = ExitCode.usage.code;
    return;
  }

  if (argResults.flag('help')) {
    print('Manage agent skill symlinks.');
    print('');
    print(parser.usage);
    return;
  }

  try {
    exitCode = await runSkillLink(configPath: argResults.option('config'));
  } catch (e, stack) {
    print('An unexpected error occurred:');
    print(e);
    print(stack);
    exitCode = ExitCode.software.code;
  }
}
