import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:collection/collection.dart';
import 'package:io/ansi.dart' as ansi;
import 'package:io/io.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'testable_print.dart';

part 'lint_cleanup.g.dart';

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

  final toKeepLints = bundle.explicit.toSet()..removeAll(bundle.included);
  final removedLints = bundle.explicit.toSet()..removeAll(toKeepLints);

  final removedLanguage = <String, dynamic>{};
  final toKeepLanguage = <String, dynamic>{};
  for (final entry in bundle.explicitLanguage.entries) {
    if (bundle.includedLanguage[entry.key] == entry.value) {
      removedLanguage[entry.key] = entry.value;
    } else {
      toKeepLanguage[entry.key] = entry.value;
    }
  }

  _printReport(
    removedLints: removedLints,
    toKeepLints: toKeepLints,
    removedLanguage: removedLanguage,
    toKeepLanguage: toKeepLanguage,
  );

  if (rewrite) {
    await _updateAnalysisOptions(
      p.fromUri(analysisOptionsUri),
      removedLints: removedLints,
      removedLanguage: removedLanguage,
    );
  }
}

void _printReport({
  required Set<String> removedLints,
  required Set<String> toKeepLints,
  required Map<String, dynamic> removedLanguage,
  required Map<String, dynamic> toKeepLanguage,
}) {
  stderr.writeln(ansi.styleBold.wrap('removed lints:'));
  if (removedLints.isEmpty) {
    stderr.writeln('NONE!');
  } else {
    stderr.writeln(removedLints.join('\n'));
  }

  if (removedLanguage.isNotEmpty) {
    stderr.writeln(ansi.styleBold.wrap('removed language options:'));
    for (final entry in removedLanguage.entries) {
      stderr.writeln('${entry.key}: ${entry.value}');
    }
  }

  stderr.writeln(ansi.styleBold.wrap('kept:'));
  print(toKeepLints.join('\n'));
}

class _LintBundle {
  final Set<String> explicit;
  final Set<String> included;
  final Map<String, dynamic> explicitLanguage;
  final Map<String, dynamic> includedLanguage;

  new({
    required this.explicit,
    required this.included,
    required this.explicitLanguage,
    required this.includedLanguage,
  });

  Set<String> get allLints => explicit.union(included);
  Map<String, dynamic> get allLanguage => {
    ...includedLanguage,
    ...explicitLanguage,
  };
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
  String analysisOptionsFile, {
  required Set<String> removedLints,
  required Map<String, dynamic> removedLanguage,
}) async {
  if (removedLints.isEmpty && removedLanguage.isEmpty) {
    stderr.writeln(
      ansi.wrapWith('No changes need to be made!', [ansi.styleBold, ansi.red]),
    );
    return;
  }

  final file = File(analysisOptionsFile);
  final editor = YamlEditor(file.readAsStringSync());
  final yamlMap = _openYamlMap(analysisOptionsFile);

  if (removedLints.isNotEmpty) {
    _removeRules(editor, yamlMap, removedLints);
  }

  if (removedLanguage.isNotEmpty) {
    _removeLanguageEntries(editor, removedLanguage.keys);
  }

  file.writeAsStringSync(editor.toString());
}

void _removeRules(YamlEditor editor, YamlMap yamlMap, Set<String> toRemove) {
  final rules = _getRules(yamlMap);
  if (rules is YamlList) {
    final indices = Map<int, String>.fromIterable(toRemove, key: rules.indexOf);
    final sortedIndices = indices.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    for (final index in sortedIndices) {
      editor.remove(['linter', 'rules', index.key]);
    }
  } else if (rules != null) {
    throw UnimplementedError(
      'Still need to add support for rules as ${rules.runtimeType}',
    );
  }
}

void _removeLanguageEntries(YamlEditor editor, Iterable<String> keysToRemove) {
  for (final key in keysToRemove) {
    editor.remove(['analyzer', 'language', key]);
  }

  final currentYaml = loadYaml(editor.toString()) as YamlMap?;
  if (currentYaml == null) return;

  final analyzer = currentYaml['analyzer'];
  if (analyzer is Map) {
    final lang = analyzer['language'];
    if (lang is Map && lang.isEmpty) {
      editor.remove(['analyzer', 'language']);
    }
  }

  final updatedYaml = loadYaml(editor.toString()) as YamlMap?;
  final updatedAnalyzer = updatedYaml?['analyzer'];
  if (updatedAnalyzer is Map && updatedAnalyzer.isEmpty) {
    editor.remove(['analyzer']);
  }
}

_LintBundle _lintsFromFile(String path, PackageConfig packageConfig) {
  final yaml = _openYamlMap(path);

  final included = <String>{};
  final includedLanguage = <String, dynamic>{};
  final includeKey = yaml['include'] as String?;
  if (includeKey != null) {
    final includeValue = _lintsFromUri(Uri.parse(includeKey), packageConfig);
    included.addAll(includeValue.allLints);
    includedLanguage.addAll(includeValue.allLanguage);
  }

  final explicit = _extractExplicitLints(yaml);
  final explicitLanguage = _extractExplicitLanguage(yaml);

  return _LintBundle(
    explicit: explicit,
    included: included,
    explicitLanguage: explicitLanguage,
    includedLanguage: includedLanguage,
  );
}

Set<String> _extractExplicitLints(YamlMap yaml) {
  final rulesValue = _getRules(yaml);
  final explicit = <String>{};
  if (rulesValue is YamlList) {
    explicit.addAll(rulesValue.cast<String>());
  } else if (rulesValue is YamlMap) {
    for (final rule in rulesValue.entries) {
      if (rule.value == true) {
        explicit.add(rule.key as String);
      }
    }
  }
  return explicit;
}

Map<String, dynamic> _extractExplicitLanguage(YamlMap yaml) {
  final analyzer = yaml['analyzer'];
  if (analyzer is Map) {
    final language = analyzer['language'];
    if (language is Map) {
      return Map<String, dynamic>.from(language);
    }
  }
  return const {};
}

YamlNode? _getRules(YamlMap yaml) {
  final linterValue = yaml['linter'] as Map?;
  return linterValue?['rules'] as YamlNode?;
}

YamlMap _openYamlMap(String path) {
  final analysisOptionsFile = File(path);
  final analysisOptionsContent = analysisOptionsFile.readAsStringSync();
  final aoYaml = loadYaml(
    analysisOptionsContent,
    sourceUrl: analysisOptionsFile.uri,
  ) as YamlMap;
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

@CliOptions()
class LintCleanupOptions {
  @CliOption(
    abbr: 'p',
    help:
        'The directory to a package within the repository that depends\n'
        'on the referenced include file. Needed for mono repos.',
  )
  final String? packageDir;

  @CliOption(
    abbr: 'r',
    help:
        'Rewrites the analysis_options.yaml file to remove duplicative '
        'entries.',
  )
  final bool rewrite;

  @CliOption(abbr: 'h', negatable: false, help: 'Prints out usage and exits')
  final bool help;

  new({this.packageDir, this.rewrite = false, this.help = false});
}

String get lintCleanupUsage => _$parserForLintCleanupOptions.usage;
