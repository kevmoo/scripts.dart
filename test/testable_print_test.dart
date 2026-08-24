import 'dart:io' as io;

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:test/scaffolding.dart';

import 'test_helpers.dart';

void main() {
  test('printError hits null assertion line in RuntimeState', () async {
    final prints = await capturePrints(() => printError(''));
    check(prints).isEmpty();
  });

  test('setError sets exitCode in RuntimeState', () {
    final original = io.exitCode;
    try {
      setError(message: 'test error', exitCode: 42);
      check(io.exitCode).equals(42);
    } finally {
      io.exitCode = original;
    }
  });

  test(
    'wrappedForTesting captures exitCode without modifying io.exitCode',
    () async {
      final original = io.exitCode;
      try {
        final code = await wrappedForTesting(() async {
          setError(message: 'test error', exitCode: 64);
        });
        check(code).equals(64);
        check(io.exitCode).equals(original);
      } finally {
        io.exitCode = original;
      }
    },
  );
}
