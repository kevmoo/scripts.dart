#!/usr/bin/env dart

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/skill_link_runner.dart';

Future<void> main(List<String> arguments) async {
  final SkillLinkOptions options;
  try {
    options = parseSkillLinkOptions(arguments);
  } on UsageException catch (e) {
    print(e.message);
    print('');
    print(e.usage);
    exitCode = ExitCode.usage.code;
    return;
  }

  if (options.help) {
    print('Manage agent skill symlinks.');
    print('');
    print(skillLinkUsage);
    return;
  }

  try {
    exitCode = await runSkillLink(configPath: options.config);
  } catch (e, stack) {
    print('An unexpected error occurred:');
    print(e);
    print(stack);
    exitCode = ExitCode.software.code;
  }
}
