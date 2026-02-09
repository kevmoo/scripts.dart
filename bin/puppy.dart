// Copyright (c) 2025, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:args/command_runner.dart';
import 'package:kevmoo_scripts/src/puppy/constants.dart';
import 'package:kevmoo_scripts/src/puppy/run_command.dart';

Future<void> main(List<String> args) async {
  final runner = CommandRunner<void>(
    cmdName,
    'Dart repository management tools.',
  )..addCommand(RunCommand());

  await runner.run(args);
}
