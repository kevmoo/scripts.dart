// Copyright (c) 2025, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/puppy.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> args) async {
  try {
    final puppyArgs = parseRunArgs(args);
    await runPuppy(puppyArgs);
  } on UsageException catch (e) {
    setError(message: e.message, exitCode: ExitCode.usage.code);
  } on PuppyException catch (e) {
    setError(message: e.message, exitCode: ExitCode.software.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
