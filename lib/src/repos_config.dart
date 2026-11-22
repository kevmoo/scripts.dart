import 'dart:io';

import 'package:io/io.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'git_up.dart';
import 'repo_align/models.dart' show RepoKind;
import 'testable_print.dart';

const _repoAlignTopLevelKey = 'repo-align';

const _allowedGitUpKeys = {
  'allowWorktree',
  'branch',
  'upstream',
  'cleanBranches',
  'before',
  'post',
  'override',
};

const _allowedRepoAlignKeys = {'owner', 'baseDir', 'active', 'ignore', 'kinds'};

/// Per-repository `git-up` configuration loaded from
/// `~/.config/kscripts/repos.yaml`.
class GitUpRepoConfig {
  final bool allowWorktree;
  final String? branch;
  final String? upstream;

  /// Whether to run gone-branch and PR cleanup after the pull.
  ///
  /// When parsed from `repos.yaml`, defaults to `true` unless [allowWorktree]
  /// is `true`, in which case it defaults to `false` and must be opted into
  /// explicitly.
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

/// Portfolio-wide `repo-align` configuration loaded from
/// `~/.config/kscripts/repos.yaml`.
final class RepoAlignConfig {
  final String owner;
  final String baseDir;
  final List<String> active;
  final List<String> ignore;

  /// Explicit [RepoKind] overrides for `active` repositories whose contents
  /// would otherwise classify them as a stricter kind (for example, an
  /// experiment that carries a `pubspec.yaml`).
  final Map<String, RepoKind> kinds;

  const new({
    required this.owner,
    required this.baseDir,
    required this.active,
    required this.ignore,
    this.kinds = const {},
  });
}

/// Loads and validates the `git-up` entry matching [repoPath] from
/// [configPath] (defaulting to `<home>/.config/kscripts/repos.yaml`).
///
/// Returns `null` when the configuration file does not exist or has no
/// `git-up` entry matching [repoPath].
///
/// Throws a [GitUpException] with [ExitCode.config] if the file contains
/// malformed YAML, duplicate canonical paths, unknown keys, or invalid field
/// types.
GitUpRepoConfig? loadGitUpRepoConfig(
  String repoPath, {
  String? configPath,
  String? homeDirectory,
}) {
  final loaded = _loadValidatedReposYaml(
    configPath: configPath,
    homeDirectory: homeDirectory,
  );
  if (loaded == null) return null;

  final canonicalTarget = _canonicalizeRepoPath(
    repoPath,
    homeDirectory: loaded.home,
  );
  return loaded.gitUpByCanonicalPath[canonicalTarget];
}

/// Loads and validates the top-level `repo-align` configuration from
/// [configPath] (defaulting to `<home>/.config/kscripts/repos.yaml`).
///
/// Returns `null` when the configuration file does not exist or has no
/// `repo-align` section.
///
/// Throws a [GitUpException] with [ExitCode.config] if any section in
/// `repos.yaml` is invalid.
RepoAlignConfig? loadRepoAlignConfig({
  String? configPath,
  String? homeDirectory,
}) => _loadValidatedReposYaml(
  configPath: configPath,
  homeDirectory: homeDirectory,
)?.repoAlign;

({
  String? home,
  Map<String, GitUpRepoConfig?> gitUpByCanonicalPath,
  RepoAlignConfig? repoAlign,
})?
_loadValidatedReposYaml({String? configPath, String? homeDirectory}) {
  final home = _effectiveHome(homeDirectory);
  final effectivePath =
      configPath ??
      (home == null ? null : p.join(home, '.config', 'kscripts', 'repos.yaml'));
  if (effectivePath == null) return null;

  final file = File(effectivePath);
  if (!file.existsSync()) return null;

  final rootMap = _readRootYamlMap(file);
  if (rootMap == null) return null;

  final seenPaths = <String, String>{};
  final gitUpByCanonicalPath = <String, GitUpRepoConfig?>{};
  RepoAlignConfig? repoAlign;

  for (final MapEntry(:key, :value) in rootMap.entries) {
    if (key is! String || key.trim().isEmpty) {
      _failConfig(
        effectivePath,
        'Repository keys must be non-empty path strings (got "$key").',
      );
    }

    if (key == _repoAlignTopLevelKey) {
      repoAlign = _parseRepoAlignSection(
        value,
        configPath: effectivePath,
        homeDirectory: home,
      );
      continue;
    }

    final canonicalKey = _canonicalizeRepoPath(
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

    gitUpByCanonicalPath[canonicalKey] = _parseGitUpSection(
      value,
      configPath: effectivePath,
      repoKey: key,
    );
  }

  return (
    home: home,
    gitUpByCanonicalPath: gitUpByCanonicalPath,
    repoAlign: repoAlign,
  );
}

RepoAlignConfig _parseRepoAlignSection(
  Object? rawValue, {
  required String configPath,
  required String? homeDirectory,
}) {
  if (rawValue is! YamlMap) {
    _failConfig(configPath, 'Top-level "repo-align" entry must be a YAML map.');
  }

  for (final key in rawValue.keys) {
    if (key is! String || !_allowedRepoAlignKeys.contains(key)) {
      final allowed = _allowedRepoAlignKeys.join(', ');
      _failConfig(
        configPath,
        'Unknown key "$key" under "repo-align" (allowed keys: $allowed).',
      );
    }
  }

  final owner = _readSectionString(
    rawValue,
    'owner',
    configPath,
    sectionLabel: '"repo-align"',
    allowEmpty: false,
  );
  if (owner == null) {
    _failConfig(configPath, 'Missing required key "owner" under "repo-align".');
  }

  final rawBaseDir = _readSectionString(
    rawValue,
    'baseDir',
    configPath,
    sectionLabel: '"repo-align"',
    allowEmpty: false,
  );
  final baseDir = _resolveRepoAlignBaseDir(
    rawBaseDir,
    owner: owner,
    homeDirectory: homeDirectory,
    configPath: configPath,
  );

  final active = _readRepoNameList(rawValue, 'active', configPath);
  final ignore = _readRepoNameList(rawValue, 'ignore', configPath);
  _validateDisjointLists(active, ignore, configPath);
  final kinds = _readRepoKindOverrides(rawValue, active, configPath);

  return RepoAlignConfig(
    owner: owner,
    baseDir: baseDir,
    active: List.unmodifiable(active),
    ignore: List.unmodifiable(ignore),
    kinds: Map.unmodifiable(kinds),
  );
}

String _resolveRepoAlignBaseDir(
  String? rawBaseDir, {
  required String owner,
  required String? homeDirectory,
  required String configPath,
}) {
  if (rawBaseDir != null) {
    return _canonicalizeRepoPath(
      rawBaseDir,
      homeDirectory: homeDirectory,
      sourceConfigPath: configPath,
    );
  }
  if (homeDirectory == null) {
    _failConfig(
      configPath,
      'Specify "baseDir" under "repo-align" when HOME is not set.',
    );
  }
  return p.canonicalize(p.join(homeDirectory, 'github', owner));
}

List<String> _readRepoNameList(YamlMap map, String key, String configPath) {
  if (!map.containsKey(key) || map[key] == null) return const [];
  final raw = map[key];
  if (raw is! YamlList) {
    _failConfig(
      configPath,
      'Key "$key" under "repo-align" must be a YAML list of repository names.',
    );
  }

  final seen = <String>{};
  final names = <String>[];
  for (final item in raw) {
    if (item is! String || item.trim().isEmpty) {
      _failConfig(
        configPath,
        'Entries in "repo-align" -> "$key" must be non-empty strings.',
      );
    }
    final trimmed = item.trim();
    if (!seen.add(trimmed)) {
      _failConfig(
        configPath,
        'Duplicate repository "$trimmed" in "repo-align" -> "$key".',
      );
    }
    names.add(trimmed);
  }
  return names;
}

Map<String, RepoKind> _readRepoKindOverrides(
  YamlMap map,
  List<String> active,
  String configPath,
) {
  final raw = map['kinds'];
  if (raw == null) return const {};
  if (raw is! YamlMap) {
    _failConfig(
      configPath,
      'Key "kinds" under "repo-align" must be a YAML map of repository name '
      'to kind.',
    );
  }

  final allowedKinds = {
    for (final kind in RepoKind.values)
      if (kind != RepoKind.legacyOrIgnored) kind.name: kind,
  };
  final activeSet = active.toSet();
  final result = <String, RepoKind>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    if (key is! String || !activeSet.contains(key)) {
      _failConfig(
        configPath,
        'Repository "$key" in "repo-align" -> "kinds" must also be listed '
        'in "active".',
      );
    }
    final kind = allowedKinds[value];
    if (kind == null) {
      _failConfig(
        configPath,
        'Invalid kind "$value" for "$key" in "repo-align" -> "kinds" '
        '(allowed: ${allowedKinds.keys.join(', ')}).',
      );
    }
    result[key] = kind;
  }
  return result;
}

void _validateDisjointLists(
  List<String> active,
  List<String> ignore,
  String configPath,
) {
  final ignoreSet = ignore.toSet();
  for (final repo in active) {
    if (ignoreSet.contains(repo)) {
      _failConfig(
        configPath,
        'Repository "$repo" cannot appear in both "active" and "ignore" under '
        '"repo-align".',
      );
    }
  }
}

/// Expands a leading `~` against [homeDirectory] (or `HOME` outside test zones)
/// and canonicalizes [rawPath], resolving symlinks when the directory exists on
/// disk.
String _canonicalizeRepoPath(
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

  final sectionLabel = '"$repoKey" -> "git-up"';
  final allowWorktree =
      _readBool(rawSection, 'allowWorktree', configPath, repoKey) ?? false;

  return GitUpRepoConfig(
    allowWorktree: allowWorktree,
    branch: _readSectionString(
      rawSection,
      'branch',
      configPath,
      sectionLabel: sectionLabel,
      allowEmpty: false,
    ),
    upstream: _readSectionString(
      rawSection,
      'upstream',
      configPath,
      sectionLabel: sectionLabel,
      allowEmpty: false,
    ),
    // Linked worktrees share branches and worktrees with every sibling in a
    // bare layout, so branch cleanup is opt-in there.
    cleanBranches:
        _readBool(rawSection, 'cleanBranches', configPath, repoKey) ??
        !allowWorktree,
    before: _readSectionString(
      rawSection,
      'before',
      configPath,
      sectionLabel: sectionLabel,
      allowEmpty: true,
    ),
    post: _readSectionString(
      rawSection,
      'post',
      configPath,
      sectionLabel: sectionLabel,
      allowEmpty: true,
    ),
    override: _readSectionString(
      rawSection,
      'override',
      configPath,
      sectionLabel: sectionLabel,
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

String? _readSectionString(
  YamlMap map,
  String key,
  String configPath, {
  required String sectionLabel,
  required bool allowEmpty,
}) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! String) {
    _failConfig(configPath, 'Key "$key" under $sectionLabel must be a string.');
  }
  final trimmed = value.trim();
  if (!allowEmpty && trimmed.isEmpty) {
    _failConfig(
      configPath,
      'Key "$key" under $sectionLabel must not be empty.',
    );
  }
  return trimmed;
}

Never _failConfig(String configPath, String reason) => throw GitUpException(
  'Error in $configPath: $reason',
  exitCode: ExitCode.config.code,
);
