import 'dart:io';

import 'package:io/io.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'git_up.dart';
import 'testable_print.dart';

const _allowedGitUpKeys = {
  'allowWorktree',
  'branch',
  'upstream',
  'cleanBranches',
  'before',
  'post',
  'override',
};

/// Per-repository `git-up` configuration loaded from
/// `~/.config/kscripts/repos.yaml`.
class GitUpRepoConfig {
  final bool allowWorktree;
  final String? branch;
  final String? upstream;
  final bool cleanBranches;
  final String? before;
  final String? post;
  final String? override;

  const new({
    this.allowWorktree = false,
    this.branch,
    this.upstream,
    this.cleanBranches = true,
    this.before,
    this.post,
    this.override,
  });
}

/// Loads and validates the `git-up` entry matching [repoPath] from
/// [configPath] (defaulting to `<home>/.config/kscripts/repos.yaml`).
///
/// Returns `null` when the configuration file does not exist or has no
/// `git-up` entry matching [repoPath].
///
/// Throws a [GitUpException] with [ExitCode.config] if the file contains
/// malformed YAML, duplicate canonical paths, unknown `git-up` keys, or
/// invalid field types.
GitUpRepoConfig? loadGitUpRepoConfig(
  String repoPath, {
  String? configPath,
  String? homeDirectory,
}) {
  final home = _effectiveHome(homeDirectory);
  final effectivePath =
      configPath ??
      (home == null ? null : p.join(home, '.config', 'kscripts', 'repos.yaml'));
  if (effectivePath == null) return null;

  final file = File(effectivePath);
  if (!file.existsSync()) return null;

  final rootMap = _readRootYamlMap(file);
  if (rootMap == null) return null;

  final canonicalTarget = canonicalizeRepoPath(repoPath, homeDirectory: home);

  final seenPaths = <String, String>{};
  GitUpRepoConfig? matched;

  for (final MapEntry(:key, :value) in rootMap.entries) {
    if (key is! String || key.trim().isEmpty) {
      _failConfig(
        effectivePath,
        'Repository keys must be non-empty path strings (got "$key").',
      );
    }

    final canonicalKey = canonicalizeRepoPath(
      key,
      homeDirectory: home,
      sourceConfigPath: effectivePath,
    );
    if (seenPaths[canonicalKey] case final previousRawKey?) {
      _failConfig(
        effectivePath,
        'Duplicate repository entries "$previousRawKey" and "$key" both '
        'resolve to "$canonicalKey".',
      );
    }
    seenPaths[canonicalKey] = key;

    final parsed = _parseGitUpSection(
      value,
      configPath: effectivePath,
      repoKey: key,
    );
    if (canonicalKey == canonicalTarget) {
      matched = parsed;
    }
  }

  return matched;
}

/// Expands a leading `~` against [homeDirectory] (or `HOME` outside test zones)
/// and canonicalizes [rawPath], resolving symlinks when the directory exists on
/// disk.
String canonicalizeRepoPath(
  String rawPath, {
  String? homeDirectory,
  String? sourceConfigPath,
}) {
  final trimmed = rawPath.trim();
  var expanded = trimmed;
  if (trimmed == '~' ||
      trimmed.startsWith('~/') ||
      (Platform.isWindows && trimmed.startsWith(r'~\'))) {
    final home = _effectiveHome(homeDirectory);
    if (home == null) {
      _failConfig(
        sourceConfigPath ?? 'repos.yaml',
        'Cannot expand "$rawPath" because HOME is not set.',
      );
    }
    expanded = trimmed == '~' ? home : p.join(home, trimmed.substring(2));
  }

  if (!p.isAbsolute(expanded)) {
    _failConfig(
      sourceConfigPath ?? 'repos.yaml',
      'Repository path "$rawPath" must be absolute or start with "~/".',
    );
  }

  final dir = Directory(expanded);
  if (dir.existsSync()) {
    return p.canonicalize(dir.resolveSymbolicLinksSync());
  }
  return p.canonicalize(expanded);
}

String? _effectiveHome(String? homeDirectory) {
  final raw =
      homeDirectory ?? (isTesting ? null : Platform.environment['HOME']);
  if (raw == null || raw.trim().isEmpty) return null;
  return raw;
}

YamlMap? _readRootYamlMap(File file) {
  final Object? doc;
  try {
    doc = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
  } on YamlException catch (e) {
    _failConfig(file.path, 'Invalid YAML syntax: ${e.message}');
  } on FileSystemException catch (e) {
    _failConfig(file.path, 'Failed to read config file: ${e.message}');
  }

  if (doc == null) return null;
  if (doc is! YamlMap) {
    _failConfig(
      file.path,
      'Top-level value must be a YAML map keyed by repository path.',
    );
  }
  return doc;
}

GitUpRepoConfig? _parseGitUpSection(
  Object? repoEntryValue, {
  required String configPath,
  required String repoKey,
}) {
  if (repoEntryValue == null) return null;
  if (repoEntryValue is! YamlMap) {
    _failConfig(
      configPath,
      'Entry for "$repoKey" must be a map of tool configurations.',
    );
  }

  final rawSection = repoEntryValue['git-up'];
  if (rawSection == null) return null;
  if (rawSection is! YamlMap) {
    _failConfig(configPath, 'Entry "$repoKey" -> "git-up" must be a YAML map.');
  }

  for (final key in rawSection.keys) {
    if (key is! String || !_allowedGitUpKeys.contains(key)) {
      final allowed = _allowedGitUpKeys.join(', ');
      _failConfig(
        configPath,
        'Unknown key "$key" under "$repoKey" -> "git-up" '
        '(allowed keys: $allowed).',
      );
    }
  }

  return GitUpRepoConfig(
    allowWorktree:
        _readBool(rawSection, 'allowWorktree', configPath, repoKey) ?? false,
    branch: _readString(
      rawSection,
      'branch',
      configPath,
      repoKey,
      allowEmpty: false,
    ),
    upstream: _readString(
      rawSection,
      'upstream',
      configPath,
      repoKey,
      allowEmpty: false,
    ),
    cleanBranches:
        _readBool(rawSection, 'cleanBranches', configPath, repoKey) ?? true,
    before: _readString(
      rawSection,
      'before',
      configPath,
      repoKey,
      allowEmpty: true,
    ),
    post: _readString(
      rawSection,
      'post',
      configPath,
      repoKey,
      allowEmpty: true,
    ),
    override: _readString(
      rawSection,
      'override',
      configPath,
      repoKey,
      allowEmpty: false,
    ),
  );
}

bool? _readBool(YamlMap map, String key, String configPath, String repoKey) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is bool) return value;
  _failConfig(
    configPath,
    'Key "$key" under "$repoKey" -> "git-up" must be a boolean.',
  );
}

String? _readString(
  YamlMap map,
  String key,
  String configPath,
  String repoKey, {
  required bool allowEmpty,
}) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! String) {
    _failConfig(
      configPath,
      'Key "$key" under "$repoKey" -> "git-up" must be a string.',
    );
  }
  final trimmed = value.trim();
  if (!allowEmpty && trimmed.isEmpty) {
    _failConfig(
      configPath,
      'Key "$key" under "$repoKey" -> "git-up" must not be empty.',
    );
  }
  return trimmed;
}

Never _failConfig(String configPath, String reason) => throw GitUpException(
  'Error in $configPath: $reason',
  exitCode: ExitCode.config.code,
);
