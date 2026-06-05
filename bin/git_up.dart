#!/usr/bin/env dart

import 'dart:io';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_up.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> arguments) async {
  final help = arguments.contains('--help') || arguments.contains('-h');
  if (help) {
    print('Safely switch to and update the default branch.');
    print('Usage: git-up [--verbose | -v] [--help | -h]');
    return;
  }

  final verbose = arguments.contains('--verbose') || arguments.contains('-v');

  try {
    await gitUp();
  } on GitUpException catch (e, stack) {
    setError(
      message: e.message,
      exitCode: e.exitCode,
      stack: verbose ? stack : null,
    );
  } on ProcessException catch (e, stack) {
    setError(
      message: 'Git error: ${e.message}',
      exitCode: 1,
      stack: verbose ? stack : null,
    );
  } catch (e, stack) {
    setError(
      message: 'Unexpected error: $e',
      exitCode: ExitCode.software.code,
      stack: verbose ? stack : null,
    );
  }
}
