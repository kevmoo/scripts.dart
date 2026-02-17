// Copyright (c) 2025, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import 'util.dart';

part 'puppy.g.dart';

Future<void> runPuppy(RunArgs args) async {
  final exe = args.rest.first;
  final extraArgs = args.rest.skip(1).toList();

  final packages = findPackages(Directory.current, deep: args.deep);
  final exits = <String, int>{};

  var count = 0;
  for (final packageDir in packages) {
    final relative = p.relative(packageDir.path);

    print(green.wrap('$relative (${++count} of ${packages.length})'));
    final proc = await Process.start(
      exe,
      extraArgs,
      mode: ProcessStartMode.inheritStdio,
      workingDirectory: packageDir.path,
    );

    // TODO(kevmoo): display a summary of results on completion
    exits[packageDir.path] = await proc.exitCode;

    print('');
  }

  final failures = exits.entries.where((entry) => entry.value != 0).toList();
  if (failures.isNotEmpty) {
    final failedPackages = failures
        .map((e) => p.relative(e.key))
        .join('\n  - ');
    throw PuppyException(
      'One or more commands failed in:\n  - $failedPackages',
    );
  }
}

class PuppyException implements Exception {
  final String message;

  PuppyException(this.message);

  @override
  String toString() => message;
}

@CliOptions()
class RunArgs {
  @CliOption(abbr: 'd', help: 'Keep looking for "nested" pubspec files.')
  final bool deep;

  @CliOption(abbr: 'h', negatable: false, help: 'Print this usage information.')
  final bool help;

  final List<String> rest;

  RunArgs({this.deep = false, this.help = false, required this.rest}) {
    if (!help && rest.isEmpty) {
      throw UsageException(
        'Missing command to invoke!',
        'puppy [--deep] <command to invoke>',
      );
    }
  }
}

String get runArgsUsage => _$parserForRunArgs.usage;
