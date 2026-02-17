import 'dart:convert';
import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

part 'tighten.g.dart';

Future<void> tighten({bool isWorkspace = false, String? cwd}) async {
  final targetDir = cwd == null ? Directory.current : Directory(cwd);
  final pubspecFile = File(p.join(targetDir.path, 'pubspec.yaml'));
  if (!await pubspecFile.exists()) {
    throw TightenException('No pubspec.yaml found in the current directory.');
  }

  Set<String>? workspacePackageNames;
  Version? workspaceSdkVersion;

  // Always check for workspace packages to warn if --workspace is missing
  Map<String, String>? workspacePackages;

  try {
    workspacePackages = await _getWorkspacePackages(cwd: targetDir.path);
  } catch (_) {
    // Ignore errors here, just means we can't detect workspace
  }

  var shouldWarn = false;
  if (workspacePackages != null && workspacePackages.length > 1) {
    if (!isWorkspace) {
      shouldWarn = true;
    } else {
      workspacePackageNames = workspacePackages.keys.toSet();
      workspaceSdkVersion = await _getWorkspaceMinSdk(workspacePackages.values);
    }
  }

  final minSdkVersion = workspaceSdkVersion ?? await _getMinSdk(pubspecFile);

  print('SDK version found: $minSdkVersion');

  final process = await Process.start(
    'dart',
    ['pub', 'downgrade', '--tighten'],
    environment: {'_PUB_TEST_SDK_VERSION': minSdkVersion.toString()},
    workingDirectory: targetDir.path,
  );

  final stdoutBuffer = StringBuffer();
  process.stdout.transform(utf8.decoder).listen((data) {
    stdout.write(data);
    if (isWorkspace) {
      stdoutBuffer.write(data);
    }
  });
  process.stderr.transform(utf8.decoder).listen(stderr.write);

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw TightenException('Process exited with code $exitCode');
  }

  if (isWorkspace && workspacePackageNames != null) {
    await _revertWorkspaceChanges(
      stdoutBuffer.toString(),
      workspacePackageNames,
      cwd: targetDir.path,
    );
  }

  if (shouldWarn) {
    print('''
\n
***********************************************************************
* WARNING: You are in a workspace but did NOT use the --workspace flag.
* This may result in unwanted changes to workspace constraints.
* Consider running with --workspace.
***********************************************************************''');
  }
}

Future<Version> _getMinSdk(File pubspecFile) async {
  final content = await pubspecFile.readAsString();
  final yaml = loadYaml(content) as YamlMap;
  final environment = yaml['environment'] as YamlMap?;
  if (environment == null) {
    throw TightenException(
      'No environment section found in ${pubspecFile.path}.',
    );
  }
  final sdkConstraintRaw = environment['sdk'] as String?;
  if (sdkConstraintRaw == null) {
    throw TightenException('No SDK constraint found in ${pubspecFile.path}.');
  }

  return switch (VersionConstraint.parse(sdkConstraintRaw)) {
    final Version version => version,
    VersionRange(:final min?) => min,
    _ => throw TightenException(
      'Could not determine minimum SDK version from constraint: '
      '$sdkConstraintRaw',
    ),
  };
}

Future<Version> _getWorkspaceMinSdk(Iterable<String> packagePaths) async {
  Version? maxMinSdk;
  for (final path in packagePaths) {
    final pubspecFile = File('$path/pubspec.yaml');
    if (await pubspecFile.exists()) {
      try {
        final sdk = await _getMinSdk(pubspecFile);
        if (maxMinSdk == null || sdk > maxMinSdk) {
          maxMinSdk = sdk;
        }
      } catch (e) {
        // Ignore errors reading individual pubspecs, but log?
        print('Warning: Could not read SDK version from $path: $e');
      }
    }
  }
  if (maxMinSdk == null) {
    throw TightenException('Could not determine workspace SDK version.');
  }
  return maxMinSdk;
}

@CliOptions()
class TightenOptions {
  @CliOption(
    abbr: 'w',
    negatable: false,
    help: 'Tighten workspace dependencies',
  )
  final bool workspace;

  @CliOption(abbr: 'h', negatable: false, help: 'Print this usage information.')
  final bool help;

  TightenOptions({this.workspace = false, this.help = false});
}

String get tightenUsage => _$parserForTightenOptions.usage;

Future<Map<String, String>> _getWorkspacePackages({required String cwd}) async {
  final process = await Process.run('dart', [
    'pub',
    'workspace',
    'list',
    '--json',
  ], workingDirectory: cwd);

  if (process.exitCode != 0) {
    throw TightenException(
      'Failed to list workspace packages: ${process.stderr}',
    );
  }

  final json = jsonDecode(process.stdout as String) as Map<String, dynamic>;
  final packages = json['packages'] as List<dynamic>;
  return {
    for (final p in packages.cast<Map>())
      p['name'] as String: p['path'] as String,
  };
}

Future<void> _revertWorkspaceChanges(
  String output,
  Set<String> workspacePackages, {
  required String cwd,
}) async {
  final fileHeaderRegex = RegExp(r'^Changed \d+ constraints? in (.*):$');
  final changeRegex = RegExp(r'^\s+([a-zA-Z0-9_]+): (.*) -> .*$');

  String? currentFile;
  final lines = output.split('\n');

  final reverts = <String, List<(String, String)>>{};

  for (final line in lines) {
    final fileMatch = fileHeaderRegex.firstMatch(line);
    if (fileMatch != null) {
      currentFile = fileMatch.group(1);
      continue;
    }

    if (currentFile != null) {
      final changeMatch = changeRegex.firstMatch(line);
      if (changeMatch != null) {
        final packageName = changeMatch.group(1)!;
        final oldValue = changeMatch.group(2)!;

        // If parsed path is relative, dart pub treats it relative to CWD.
        // We use it as is with File(currentFile).

        if (workspacePackages.contains(packageName)) {
          reverts.putIfAbsent(currentFile, () => []).add((
            packageName,
            oldValue,
          ));
        }
      }
    }
  }

  if (reverts.isNotEmpty) {
    print('\nReverting changes to workspace packages:');
    for (final entry in reverts.entries) {
      final file = entry.key;
      final changes = entry.value;
      print('  $file:');
      for (final (packageName, oldValue) in changes) {
        print('    - $packageName (restoring $oldValue)');
        await _revertConstraint(p.join(cwd, file), packageName, oldValue);
      }
    }
  }
}

Future<void> _revertConstraint(
  String filePath,
  String packageName,
  String oldValue,
) async {
  final file = File(filePath);
  if (!await file.exists()) {
    print('Warning: File not found: $filePath');
    return;
  }

  final content = await file.readAsString();
  final editor = YamlEditor(content);

  // Find where the dependency is defined to update it.

  final yaml = loadYaml(content) as YamlMap;
  final dependencies = yaml['dependencies'] as YamlMap?;
  final devDependencies = yaml['dev_dependencies'] as YamlMap?;

  if (dependencies != null && dependencies.containsKey(packageName)) {
    editor.update(['dependencies', packageName], oldValue);
  } else if (devDependencies != null &&
      devDependencies.containsKey(packageName)) {
    editor.update(['dev_dependencies', packageName], oldValue);
  } else {
    print('Warning: Could not find $packageName in $filePath to revert.');
    return;
  }

  await file.writeAsString(editor.toString());
}

class TightenException implements Exception {
  final String message;
  TightenException(this.message);

  @override
  String toString() => 'TightenException: $message';
}
