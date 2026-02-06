import 'dart:io';

import 'package:collection/collection.dart';
import 'package:io/ansi.dart' as ansi;
import 'package:io/io.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'testable_print.dart';

Future<void> lintCleanup({
  required Directory packageDirectory,
  Directory? directoryWithAnalysisOptions,
  bool rewrite = false,
}) async {
  final config = await findPackageConfig(packageDirectory);

  if (config == null) {
    setError(
      message: 'No package was found in directory `${packageDirectory.path}`',
      exitCode: ExitCode.config.code,
    );
    return;
  }

  directoryWithAnalysisOptions ??= Directory.current;

  final analysisOptionsUri = directoryWithAnalysisOptions.uri.resolve(
    'analysis_options.yaml',
  );

  final bundle = _lintsFromUri(analysisOptionsUri, config);

  final toKeep = bundle.explicit.toSet()..removeAll(bundle.included);

  final removed = bundle.explicit.toSet()..removeAll(toKeep);

  stderr.writeln(ansi.styleBold.wrap('removed:'));
  if (removed.isEmpty) {
    stderr.writeln('NONE!');
  } else {
    stderr.writeln(removed.join('\n'));
  }

  stderr.writeln(ansi.styleBold.wrap('kept:'));

  print(toKeep.join('\n'));

  if (rewrite) {
    await _updateAnalysisOptions(p.fromUri(analysisOptionsUri), removed);
  }
}

class _LintBundle {
  _LintBundle({required this.explicit, required this.included});

  final Set<String> explicit;
  final Set<String> included;

  Set<String> get allLints => explicit.union(included);
}

_LintBundle _lintsFromUri(Uri analysisOptionsUri, PackageConfig packageConfig) {
  if (analysisOptionsUri.isScheme('file')) {
    return _lintsFromFile(p.fromUri(analysisOptionsUri), packageConfig);
  }

  if (analysisOptionsUri.isScheme('package')) {
    return _analysisOptionsFromPackage(analysisOptionsUri, packageConfig);
  }

  throw UnimplementedError('for uri $analysisOptionsUri');
}

Future<void> _updateAnalysisOptions(
  String analysisOptionsFile,
  Set<String> toRemove,
) async {
  if (toRemove.isEmpty) {
    stderr.writeln(
      ansi.wrapWith('No changes need to be made!', [ansi.styleBold, ansi.red]),
    );
    return;
  }

  final file = File(analysisOptionsFile);

  final editor = YamlEditor(file.readAsStringSync());

  final yamlMap = _openYamlMap(analysisOptionsFile);
  final rules = _getRules(yamlMap)!;

  if (rules is YamlList) {
    final indices = Map<int, String>.fromIterable(toRemove, key: rules.indexOf);

    final sortedIndices = indices.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    for (var index in sortedIndices) {
      editor.remove(['linter', 'rules', index.key]);
    }
  } else {
    throw UnimplementedError(
      'Still need to add support for rules as ${rules.runtimeType}',
    );
  }

  file.writeAsStringSync(editor.toString());
}

_LintBundle _lintsFromFile(String path, PackageConfig packageConfig) {
  final yaml = _openYamlMap(path);

  final included = <String>{};
  final includeKey = yaml['include'] as String?;
  if (includeKey != null) {
    final includeValue = _lintsFromUri(Uri.parse(includeKey), packageConfig);
    included.addAll(includeValue.allLints);
  }

  final rulesValue = _getRules(yaml);

  final explicit = <String>{};
  if (rulesValue is YamlList) {
    explicit.addAll(rulesValue.cast<String>());
  }
  if (rulesValue is YamlMap) {
    for (final rule in rulesValue.entries) {
      if (rule.value == true) {
        explicit.add(rule.key as String);
      }
    }
  }

  return _LintBundle(explicit: explicit, included: included);
}

YamlNode? _getRules(YamlMap yaml) {
  final linterValue = yaml['linter'] as Map?;
  return linterValue?['rules'] as YamlNode?;
}

YamlMap _openYamlMap(String path) {
  final analysisOptionsFile = File(path);

  final analysisOptionsContent = analysisOptionsFile.readAsStringSync();

  final aoYaml =
      loadYaml(analysisOptionsContent, sourceUrl: analysisOptionsFile.uri)
          as YamlMap;

  return aoYaml;
}

_LintBundle _analysisOptionsFromPackage(
  Uri includeUri,
  PackageConfig packageConfig,
) {
  if (!includeUri.isScheme('package')) {
    throw ArgumentError('`$includeUri` is not a package!');
  }

  final pkg = includeUri.pathSegments.first;

  final usedLintsPkg = packageConfig.packages.firstWhereOrNull(
    (p) => p.name == pkg,
  );

  if (usedLintsPkg == null) {
    throw StateError('Could not find the package `$pkg` in package config');
  }

  final segments = includeUri.pathSegments.skip(1).toList();
  if (segments.any((s) => s == '..')) {
    throw ArgumentError('Invalid path segments in include URI: $includeUri');
  }

  final yamlPath = usedLintsPkg.root.resolve(p.joinAll(['lib', ...segments]));

  return _lintsFromFile(p.fromUri(yamlPath), packageConfig);
}
