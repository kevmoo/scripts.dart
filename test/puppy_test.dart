import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:kevmoo_scripts/src/puppy.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  test('no arguments', () async {
    await d.dir('pkg_a', [d.file('pubspec.yaml', 'name: pkg_a')]).create();

    // parseRunArgs throws UsageException directly
    expect(() => parseRunArgs([]), throwsA(isA<UsageException>()));
  });

  test('dart pub upgrade - success', () async {
    await d.dir('pkg_a', [d.file('pubspec.yaml', 'name: pkg_a')]).create();

    await _runInDir(d.sandbox, () async {
      await wrappedForTesting(() async {
        final args = parseRunArgs(['echo', 'hello']);
        await runPuppy(args);
      });
    });
  });

  test('dart monkey - failure', () async {
    await d.dir('pkg_a', [d.file('pubspec.yaml', 'name: pkg_a')]).create();

    await _runInDir(d.sandbox, () async {
      await wrappedForTesting(() async {
        final args = parseRunArgs(['false']);
        expect(() => runPuppy(args), throwsA(isA<PuppyException>()));
      });
    });
  });
}

Future<T> _runInDir<T>(String path, Future<T> Function() action) async {
  final original = Directory.current;
  Directory.current = path;
  try {
    return await action();
  } finally {
    Directory.current = original;
  }
}
