import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Resolved bundle of explicit and inherited linter rules and language options.
class ResolvedAnalysisOptions {
  final Set<String> explicitLints;
  final Set<String> includedLints;
  final Map<String, dynamic> explicitLanguage;
  final Map<String, dynamic> includedLanguage;

  new({
    required this.explicitLints,
    required this.includedLints,
    required this.explicitLanguage,
    required this.includedLanguage,
  });

  Set<String> get allLints => explicitLints.union(includedLints);
  Map<String, dynamic> get allLanguage => {
    ...includedLanguage,
    ...explicitLanguage,
  };
}

/// Helper that recursively resolves `analysis_options.yaml` files and includes.
class AnalysisOptionsResolver {
  final PackageConfig? packageConfig;

  new({this.packageConfig});

  /// Factory that attempts to find package config synchronously from
  /// [packageDirectory], falling back to [fallbackDirectory] or ambient.
  static AnalysisOptionsResolver createSync({
    required Directory packageDirectory,
    Directory? fallbackDirectory,
  }) {
    var config = _loadPackageConfigSync(packageDirectory);
    if (config == null && fallbackDirectory != null) {
      config = _loadPackageConfigSync(fallbackDirectory);
    }
    config ??= _loadPackageConfigSync(Directory.current);
    return AnalysisOptionsResolver(packageConfig: config);
  }

  static PackageConfig? _loadPackageConfigSync(Directory dir) {
    final configFile = File(
      p.join(dir.path, '.dart_tool', 'package_config.json'),
    );
    if (configFile.existsSync()) {
      try {
        final content = configFile.readAsStringSync();
        final jsonObject = jsonDecode(content);
        return PackageConfig.parseJson(jsonObject, configFile.uri);
      } catch (_) {}
    }
    return null;
  }

  /// Factory that attempts to find package config asynchronously from
  /// [packageDirectory], falling back to [fallbackDirectory] or ambient.
  static Future<AnalysisOptionsResolver> create({
    required Directory packageDirectory,
    Directory? fallbackDirectory,
  }) async {
    var config = await findPackageConfig(packageDirectory);
    if (config == null && fallbackDirectory != null) {
      config = await findPackageConfig(fallbackDirectory);
    }
    config ??= await findPackageConfig(Directory.current);
    return AnalysisOptionsResolver(packageConfig: config);
  }

  /// Resolve analysis options from a file or package URI.
  ResolvedAnalysisOptions resolveFromUri(Uri uri) {
    if (uri.isScheme('file')) {
      return _resolveFromFile(p.fromUri(uri));
    }
    if (uri.isScheme('package')) {
      return _resolveFromPackage(uri);
    }
    throw UnimplementedError('Unsupported URI scheme: $uri');
  }

  /// Resolve analysis options directly from a file path.
  ResolvedAnalysisOptions resolveFromFile(String filePath) =>
      _resolveFromFile(filePath);

  ResolvedAnalysisOptions _resolveFromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return ResolvedAnalysisOptions(
        explicitLints: const {},
        includedLints: const {},
        explicitLanguage: const {},
        includedLanguage: const {},
      );
    }

    final yaml = _openYamlMap(path);
    final includedLints = <String>{};
    final includedLanguage = <String, dynamic>{};

    final includeKey = yaml['include'] as String?;
    if (includeKey != null) {
      final includeUri = Uri.tryParse(includeKey);
      if (includeUri != null) {
        final inherited = _safeResolveUri(includeUri);
        if (inherited != null) {
          includedLints.addAll(inherited.allLints);
          includedLanguage.addAll(inherited.allLanguage);
        }
      }
    }

    final explicitLints = _extractExplicitLints(yaml);
    final explicitLanguage = _extractExplicitLanguage(yaml);

    return ResolvedAnalysisOptions(
      explicitLints: explicitLints,
      includedLints: includedLints,
      explicitLanguage: explicitLanguage,
      includedLanguage: includedLanguage,
    );
  }

  ResolvedAnalysisOptions? _safeResolveUri(Uri uri) {
    try {
      return resolveFromUri(uri);
    } catch (_) {
      return null;
    }
  }

  ResolvedAnalysisOptions _resolveFromPackage(Uri includeUri) {
    final config = packageConfig;
    if (config == null) {
      throw StateError(
        'Cannot resolve $includeUri without a valid PackageConfig',
      );
    }

    final pkgName = includeUri.pathSegments.first;
    final pkg = config.packages.firstWhereOrNull((p) => p.name == pkgName);
    if (pkg == null) {
      throw StateError('Package `$pkgName` not found in package config');
    }

    final segments = includeUri.pathSegments.skip(1).toList();
    if (segments.any((s) => s == '..')) {
      throw ArgumentError('Invalid path segments in include URI: $includeUri');
    }

    final resolvedFile = pkg.root.resolve(p.joinAll(['lib', ...segments]));
    return _resolveFromFile(p.fromUri(resolvedFile));
  }

  Set<String> _extractExplicitLints(YamlMap yaml) {
    final linter = yaml['linter'];
    if (linter is! Map) return const {};
    final rules = linter['rules'];
    final explicit = <String>{};
    if (rules is YamlList) {
      explicit.addAll(rules.cast<String>());
    } else if (rules is YamlMap) {
      for (final rule in rules.entries) {
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

  YamlMap _openYamlMap(String path) {
    try {
      final content = File(path).readAsStringSync();
      final yaml = loadYaml(content, sourceUrl: Uri.file(path));
      if (yaml is YamlMap) return yaml;
    } catch (_) {}
    return YamlMap();
  }
}
