#!/usr/bin/env dart

// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_org_clean.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> args) async {
  try {
    final cleanArgs = parseCleanArgs(args);
    if (cleanArgs.help) {
      print('Analyze a GitHub organization for archive/delete candidates.');
      print('');
      print('Usage: git-org-clean [arguments]');
      print('');
      print('Options:');
      print(cleanArgsUsage);
      return;
    }
    await runGitOrgClean(cleanArgs);
  } on UsageException catch (e) {
    setError(message: e.message, exitCode: ExitCode.usage.code);
  } on ProcessException catch (e) {
    setError(message: e.message, exitCode: ExitCode.software.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
