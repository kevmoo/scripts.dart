@TestOn('vm')
@Timeout.factor(2)
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  test('ensure_build', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'build_cli@2.3.0',
      '--check',
    ]);
    check(
      because: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      result.exitCode,
    ).equals(0);
  });
}
