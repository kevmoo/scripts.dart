#!/usr/bin/env dart

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/dart_clean.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> args) async {
  try {
    final options = parseDartCleanOptions(args);

    if (options.help) {
      print('Find and kill orphaned Dart processes.');
      print('');
      print(dartCleanOptionsUsage);
      return;
    }

    await runDartClean(options);
  } on FormatException catch (e) {
    print(e.message);
    print('');
    print(dartCleanOptionsUsage);
    exitCode = ExitCode.usage.code;
  } on DartCleanException catch (e) {
    setError(message: e.message, exitCode: ExitCode.software.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
