import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

Future<void> tighten() async {
  final pubspecFile = File('pubspec.yaml');
  if (!await pubspecFile.exists()) {
    throw TightenException('No pubspec.yaml found in the current directory.');
  }

  final pubspecContent = await pubspecFile.readAsString();
  final pubspec = loadYaml(pubspecContent) as YamlMap;

  final environment = pubspec['environment'] as YamlMap?;
  if (environment == null) {
    throw TightenException('No environment section found in pubspec.yaml.');
  }

  final sdkConstraintRaw = environment['sdk'] as String?;
  if (sdkConstraintRaw == null) {
    throw TightenException('No SDK constraint found in pubspec.yaml.');
  }

  final minSdkVersion = switch (VersionConstraint.parse(sdkConstraintRaw)) {
    final Version version => version,
    VersionRange(:final min?) => min,
    _ => throw TightenException(
      'Could not determine minimum SDK version from constraint: '
      '$sdkConstraintRaw',
    ),
  };

  print('SDK version found: $minSdkVersion');

  final process = await Process.start(
    'dart',
    ['pub', 'downgrade', '--tighten'],
    environment: {'_PUB_TEST_SDK_VERSION': minSdkVersion.toString()},
    mode: ProcessStartMode.inheritStdio,
  );

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw TightenException('Process exited with code $exitCode');
  }
}

class TightenException implements Exception {
  final String message;
  TightenException(this.message);

  @override
  String toString() => 'TightenException: $message';
}
