import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('do the work', () {
    print(_lintsVersion());
  });
}

Version? _lintsVersion() {
  final lockFile = File('pubspec.lock');

  final lockYaml =
      loadYaml(lockFile.readAsStringSync(), sourceUrl: lockFile.uri) as Map;

  final packages = lockYaml['packages'] as Map;
  final lints = packages['lints'] as Map?;

  if (lints == null) return null;

  return Version.parse(lints['version'] as String);
}
