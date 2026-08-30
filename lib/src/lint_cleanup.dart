import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/ansi.dart' as ansi;
import 'package:io/io.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'shared/analysis_options_resolver.dart';
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

  final analysisOptionsFile = File(
    p.join(directoryWithAnalysisOptions.path, 'analysis_options.yaml'),
  );

  final resolver = AnalysisOptionsResolver(packageConfig: config);
  final bundle = resolver.resolveFromFile(analysisOptionsFile.path);

  final toKeepLints = bundle.explicitLints.toSet()
    ..removeAll(bundle.includedLints);
  final removedLints = bundle.explicitLints.toSet()..removeAll(toKeepLints);

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
      analysisOptionsFile.path,
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
  final linter = yamlMap['linter'];
  final rules = linter is Map ? linter['rules'] : null;
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

YamlMap _openYamlMap(String path) {
  try {
    final content = File(path).readAsStringSync();
    final yaml = loadYaml(content, sourceUrl: Uri.file(path));
    if (yaml is YamlMap) return yaml;
  } catch (_) {}
  return YamlMap();
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
