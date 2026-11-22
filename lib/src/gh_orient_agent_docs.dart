/// Repository-local agent instruction and skill discovery for `gh-orient`.
///
/// Scans local Git checkouts, remote GitHub repositories (via GraphQL), and
/// monorepo directories for agent instruction files (`AGENTS.md`, `CLAUDE.md`,
/// `GEMINI.md`, `.gemini/styleguide.md`, `.github/copilot-instructions.md`,
/// `.agents/rules/*.md`) and repository-local skills (`SKILL.md`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'gh_orient.dart' show OrientCommandRunner;

const _rootDocCandidates = [
  'AGENTS.md',
  'CLAUDE.md',
  'GEMINI.md',
  '.gemini/styleguide.md',
  '.github/copilot-instructions.md',
];

const _nestedDocCandidates = ['AGENTS.md', 'CLAUDE.md', 'GEMINI.md'];

const _ruleDirCandidates = [
  '.agents/rules',
  '.claude/rules',
  '.gemini/rules',
  '.github/instructions',
];

const _skillDirCandidates = [
  '.agents/skills',
  '.claude/skills',
  '.gemini/skills',
  'skills',
];

/// Git tree entry file mode for a symbolic link (`0120000`).
const _gitSymlinkMode = 40960;

/// Maximum number of `sites/*` subtrees queried per GraphQL batch.
const _remoteSitesBatchSize = 10;

/// Maximum character length of a rendered one-line skill summary.
const _maxSummaryLength = 120;

final _safeSegmentPattern = RegExp(r'^[a-zA-Z0-9._-]+$');
final _repoSlugPattern = RegExp(r'^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$');

typedef _CandidateEntry = ({
  String displayPath,
  String canonicalKey,
  bool isSymlink,
  String? summary,
});

/// Discovered repository-level agent instruction files and skill manifests.
class DiscoveredAgentSetup {
  final List<String> agentDocs;
  final List<String> agentSkills;
  final Map<String, String> agentSkillSummaries;

  const new({
    this.agentDocs = const [],
    this.agentSkills = const [],
    this.agentSkillSummaries = const {},
  });
}

/// Extracts a concise one-line summary from a `SKILL.md` frontmatter
/// `description` field, or `null` if unavailable.
String? extractSkillSummary(String content) {
  final lines = content.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  final closeIdx = lines.indexOf('---', 1);
  if (closeIdx <= 1) return null;

  try {
    final parsed = loadYaml(lines.sublist(1, closeIdx).join('\n'));
    if (parsed is! YamlMap) return null;
    final raw = parsed['description']?.toString() ?? '';
    return _summarizeDescriptionText(raw);
  } on YamlException {
    return null;
  }
}

String? _summarizeDescriptionText(String raw) {
  final compact = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty) return null;

  final triggerCut = RegExp(
    r'\s+(?:Use when|Don\x27t use for|Do not use for|Triggered via)\b',
  ).firstMatch(compact);
  final lead = triggerCut != null
      ? compact.substring(0, triggerCut.start).trim()
      : compact;

  final sentenceMatch = RegExp(r'^(.+?\.)\s').firstMatch('$lead ');
  final sentence = (sentenceMatch?.group(1) ?? lead).trim();
  if (sentence.length <= _maxSummaryLength) return sentence;
  return '${sentence.substring(0, _maxSummaryLength - 3).trimRight()}...';
}

/// Scans a local repository checkout at [targetDir] for agent instructions and
/// skill manifests, deduplicating symlink aliases and scoping `sites/*`
/// subtrees when [paths] is non-empty.
DiscoveredAgentSetup scanLocalAgentSetup(
  String targetDir, {
  List<String> paths = const [],
}) {
  final rootPath = p.normalize(Directory(targetDir).absolute.path);
  final docCandidates = <_CandidateEntry>[
    ..._localDocCandidates(rootPath, '', _rootDocCandidates),
    for (final ruleDir in _ruleDirCandidates)
      ..._localRuleCandidates(rootPath, ruleDir),
  ];
  final skillCandidates = <_CandidateEntry>[
    for (final skillDir in _skillDirCandidates)
      ..._localSkillCandidates(rootPath, skillDir),
  ];

  final sitesDir = p.join(rootPath, 'sites');
  for (final site in _listChildDirectoryNames(sitesDir)) {
    if (!_siteMatchesPaths(site, paths)) continue;
    final sitePath = p.join(sitesDir, site);
    final sitePrefix = 'sites/$site';
    docCandidates
      ..addAll(_localDocCandidates(sitePath, sitePrefix, _nestedDocCandidates))
      ..addAll(_localRuleCandidates(rootPath, '$sitePrefix/.agents/rules'));
    skillCandidates.addAll(
      _localSkillCandidates(rootPath, '$sitePrefix/.agents/skills'),
    );
  }

  return _buildDiscoveredSetup(docCandidates, skillCandidates);
}

/// Scans a monorepo directory at [targetDir] (and ancestor directories up to
/// the `google3` root) for agent instructions and local skill manifests.
DiscoveredAgentSetup scanGoogle3AgentSetup(String targetDir) {
  final startDir = resolveGoogle3StartDir(targetDir);
  final google3Root = _findGoogle3RootAncestor(startDir);

  final docCandidates = <_CandidateEntry>[];
  Directory? curr = Directory(startDir);
  while (curr != null && curr.path != curr.parent.path) {
    final prefix = _google3DisplayPrefix(curr.path, startDir, google3Root);
    docCandidates.addAll(
      _localDocCandidates(curr.path, prefix, _nestedDocCandidates),
    );
    if (google3Root != null && p.equals(curr.path, google3Root)) break;
    curr = curr.parent;
  }

  for (final ruleDir in const ['_agents/rules', '.agents/rules']) {
    docCandidates.addAll(_localRuleCandidates(startDir, ruleDir));
  }
  final skillCandidates = <_CandidateEntry>[
    for (final dir in const ['_agents/skills', '.agents/skills', 'skills'])
      ..._localSkillCandidates(startDir, dir),
  ];

  return _buildDiscoveredSetup(docCandidates, skillCandidates);
}

/// Resolves the normalized monorepo start directory, descending into a child
/// `google3/` directory when [targetDir] is a workspace root.
String resolveGoogle3StartDir(String targetDir) {
  final normalizedDir = p.normalize(Directory(targetDir).absolute.path);
  if (p.split(normalizedDir).contains('google3')) return normalizedDir;
  final child = Directory(p.join(normalizedDir, 'google3'));
  return child.existsSync() ? child.path : normalizedDir;
}

String? _findGoogle3RootAncestor(String startDir) {
  Directory? curr = Directory(startDir);
  while (curr != null && curr.path != curr.parent.path) {
    if (p.basename(curr.path) == 'google3') return curr.path;
    curr = curr.parent;
  }
  return null;
}

String _google3DisplayPrefix(
  String dirPath,
  String startDir,
  String? google3Root,
) {
  if (p.equals(dirPath, startDir)) return '';
  if (google3Root != null && p.isWithin(google3Root, dirPath)) {
    final rel = p.posix.joinAll(
      p.split(p.relative(dirPath, from: google3Root)),
    );
    return '//$rel';
  }
  if (google3Root != null && p.equals(dirPath, google3Root)) return '//';
  return p.basename(dirPath);
}

bool _siteMatchesPaths(String siteName, List<String> paths) {
  if (paths.isEmpty) return true;
  final sitePrefix = 'sites/$siteName';
  for (final raw in paths) {
    final norm = p.posix
        .normalize(raw.replaceAll(r'\', '/').trim())
        .replaceFirst(RegExp(r'^\./'), '');
    if (norm == sitePrefix || norm.startsWith('$sitePrefix/')) return true;
  }
  return false;
}

List<_CandidateEntry> _localDocCandidates(
  String baseDir,
  String relPrefix,
  List<String> names,
) {
  final entries = <_CandidateEntry>[];
  for (final rel in names) {
    final filePath = p.joinAll([baseDir, ...rel.split('/')]);
    final entry = _readLocalCandidate(
      filePath,
      _joinDisplayPath(relPrefix, rel),
      readSummary: false,
    );
    if (entry != null) entries.add(entry);
  }
  return entries;
}

List<_CandidateEntry> _localRuleCandidates(String rootDir, String relRuleDir) {
  final dirPath = p.joinAll([rootDir, ...relRuleDir.split('/')]);
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const [];
  final dirIsLink = _hasSymlinkSegment(rootDir, relRuleDir);
  final entries = <_CandidateEntry>[];
  for (final name in _listMarkdownRuleFiles(dir)) {
    final entry = _readLocalCandidate(
      p.join(dirPath, name),
      '$relRuleDir/$name',
      parentIsLink: dirIsLink,
      readSummary: false,
    );
    if (entry != null) entries.add(entry);
  }
  return entries;
}

List<_CandidateEntry> _localSkillCandidates(
  String rootDir,
  String relSkillDir,
) {
  final dirPath = p.joinAll([rootDir, ...relSkillDir.split('/')]);
  final parentIsLink = _hasSymlinkSegment(rootDir, relSkillDir);
  final entries = <_CandidateEntry>[];
  for (final skillName in _listChildDirectoryNames(dirPath)) {
    final skillDirPath = p.join(dirPath, skillName);
    final isLink =
        parentIsLink ||
        FileSystemEntity.typeSync(skillDirPath, followLinks: false) ==
            FileSystemEntityType.link;
    final entry = _readLocalCandidate(
      p.join(skillDirPath, 'SKILL.md'),
      '$relSkillDir/$skillName/SKILL.md',
      parentIsLink: isLink,
      readSummary: true,
    );
    if (entry != null) entries.add(entry);
  }
  return entries;
}

bool _hasSymlinkSegment(String rootDir, String relPath) {
  var current = rootDir;
  for (final part in relPath.split('/')) {
    current = p.join(current, part);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      return true;
    }
  }
  return false;
}

_CandidateEntry? _readLocalCandidate(
  String filePath,
  String displayPath, {
  bool parentIsLink = false,
  required bool readSummary,
}) {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final resolved = file.resolveSymbolicLinksSync();
    final fileIsLink =
        parentIsLink ||
        FileSystemEntity.typeSync(filePath, followLinks: false) ==
            FileSystemEntityType.link;
    final summary = readSummary
        ? extractSkillSummary(file.readAsStringSync())
        : null;
    return (
      displayPath: displayPath,
      canonicalKey: resolved,
      isSymlink: fileIsLink,
      summary: summary,
    );
  } on FileSystemException {
    return null;
  }
}

DiscoveredAgentSetup _buildDiscoveredSetup(
  List<_CandidateEntry> docCandidates,
  List<_CandidateEntry> skillCandidates,
) {
  final dedupedDocs = _deduplicateCandidates(docCandidates);
  final dedupedSkills = _deduplicateCandidates(skillCandidates);
  return DiscoveredAgentSetup(
    agentDocs: [for (final d in dedupedDocs) d.displayPath],
    agentSkills: [for (final s in dedupedSkills) s.displayPath],
    agentSkillSummaries: {
      for (final s in dedupedSkills)
        if (s.summary != null) s.displayPath: s.summary!,
    },
  );
}

List<_CandidateEntry> _deduplicateCandidates(List<_CandidateEntry> candidates) {
  final seenKeys = <String>{};
  final acceptedIndices = <int>[];

  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    if (!c.isSymlink && seenKeys.add(c.canonicalKey)) {
      acceptedIndices.add(i);
    }
  }
  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    if (c.isSymlink && seenKeys.add(c.canonicalKey)) {
      acceptedIndices.add(i);
    }
  }
  acceptedIndices.sort();
  return [for (final i in acceptedIndices) candidates[i]];
}

String _joinDisplayPath(String prefix, String rel) {
  if (prefix.isEmpty) return rel;
  if (prefix == '//') return '//$rel';
  return '$prefix/$rel';
}

List<String> _listMarkdownRuleFiles(Directory dir) {
  try {
    final names = <String>[];
    for (final entry in dir.listSync()) {
      final name = p.basename(entry.path);
      if (!name.endsWith('.md') || name.toUpperCase() == 'README.MD') continue;
      if (File(entry.path).existsSync()) names.add(name);
    }
    names.sort();
    return names;
  } on FileSystemException {
    return const [];
  }
}

List<String> _listChildDirectoryNames(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const [];
  try {
    final names = <String>[];
    for (final entry in dir.listSync()) {
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue;
      if (Directory(entry.path).existsSync()) names.add(name);
    }
    names.sort();
    return names;
  } on FileSystemException {
    return const [];
  }
}

const _remoteAgentSetupGraphQl = r'''
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    root: object(expression: "HEAD:") {
      ... on Tree { entries { name type mode } }
    }
    agentsMd: object(expression: "HEAD:AGENTS.md") { ... on Blob { text } }
    claudeMd: object(expression: "HEAD:CLAUDE.md") { ... on Blob { text } }
    geminiMd: object(expression: "HEAD:GEMINI.md") { ... on Blob { text } }
    dotGemini: object(expression: "HEAD:.gemini") {
      ... on Tree {
        entries { name type mode object { ... on Blob { isBinary text } } }
      }
    }
    dotGithub: object(expression: "HEAD:.github") {
      ... on Tree {
        entries { name type mode object { ... on Blob { isBinary text } } }
      }
    }
    agentsRules: object(expression: "HEAD:.agents/rules") {
      ... on Tree {
        entries { name type mode object { ... on Blob { isBinary text } } }
      }
    }
    claudeRules: object(expression: "HEAD:.claude/rules") {
      ... on Tree {
        entries { name type mode object { ... on Blob { isBinary text } } }
      }
    }
    geminiRules: object(expression: "HEAD:.gemini/rules") {
      ... on Tree {
        entries { name type mode object { ... on Blob { isBinary text } } }
      }
    }
    githubInstructions: object(expression: "HEAD:.github/instructions") {
      ... on Tree {
        entries { name type mode object { ... on Blob { isBinary text } } }
      }
    }
    agentsSkills: object(expression: "HEAD:.agents/skills") {
      ... on Tree {
        entries {
          name
          type
          mode
          object {
            ... on Tree {
              entries {
                name
                type
                mode
                object { ... on Blob { isBinary text } }
              }
            }
          }
        }
      }
    }
    claudeSkills: object(expression: "HEAD:.claude/skills") {
      ... on Tree {
        entries {
          name
          type
          mode
          object {
            ... on Tree {
              entries {
                name
                type
                mode
                object { ... on Blob { isBinary text } }
              }
            }
          }
        }
      }
    }
    geminiSkills: object(expression: "HEAD:.gemini/skills") {
      ... on Tree {
        entries {
          name
          type
          mode
          object {
            ... on Tree {
              entries {
                name
                type
                mode
                object { ... on Blob { isBinary text } }
              }
            }
          }
        }
      }
    }
    rootSkills: object(expression: "HEAD:skills") {
      ... on Tree {
        entries {
          name
          type
          mode
          object {
            ... on Tree {
              entries {
                name
                type
                mode
                object { ... on Blob { isBinary text } }
              }
            }
          }
        }
      }
    }
    sites: object(expression: "HEAD:sites") {
      ... on Tree { entries { name type } }
    }
  }
}
''';

/// Queries a remote GitHub repository (`owner/repo`) via GraphQL for agent
/// instruction files and skill manifests without cloning.
Future<DiscoveredAgentSetup> scanRemoteAgentSetup(
  String targetDir,
  String remoteRepo,
  OrientCommandRunner runCmd, {
  List<String> paths = const [],
}) async {
  final slug = _parseRepoSlug(remoteRepo);
  if (slug == null) return const DiscoveredAgentSetup();

  final repoMap = await _runRepoGraphQl(
    targetDir,
    slug,
    _remoteAgentSetupGraphQl,
    runCmd,
  );
  if (repoMap == null) return const DiscoveredAgentSetup();

  final docCandidates = <_CandidateEntry>[
    ..._remoteRootDocs(repoMap),
    ..._remoteNamedDoc(repoMap['dotGemini'], '.gemini', 'styleguide.md'),
    ..._remoteNamedDoc(
      repoMap['dotGithub'],
      '.github',
      'copilot-instructions.md',
    ),
    ..._remoteRuleBlobs(repoMap['agentsRules'], '.agents/rules'),
    ..._remoteRuleBlobs(repoMap['claudeRules'], '.claude/rules'),
    ..._remoteRuleBlobs(repoMap['geminiRules'], '.gemini/rules'),
    ..._remoteRuleBlobs(repoMap['githubInstructions'], '.github/instructions'),
  ];

  final skillCandidates = <_CandidateEntry>[
    ..._remoteSkills(repoMap['agentsSkills'], '.agents/skills'),
    ..._remoteSkills(repoMap['claudeSkills'], '.claude/skills'),
    ..._remoteSkills(repoMap['geminiSkills'], '.gemini/skills'),
    ..._remoteSkills(repoMap['rootSkills'], 'skills'),
  ];

  final siteNames = [
    for (final s in _extractSafeSubtreeNames(repoMap['sites']))
      if (_siteMatchesPaths(s, paths)) s,
  ];
  if (siteNames.isNotEmpty) {
    final siteEntries = await _scanRemoteSites(
      targetDir,
      slug,
      siteNames,
      runCmd,
    );
    docCandidates.addAll(siteEntries.docs);
    skillCandidates.addAll(siteEntries.skills);
  }

  return _buildDiscoveredSetup(docCandidates, skillCandidates);
}

({String owner, String name})? _parseRepoSlug(String raw) {
  final trimmed = raw.trim();
  if (!_repoSlugPattern.hasMatch(trimmed)) return null;
  final slash = trimmed.indexOf('/');
  return (
    owner: trimmed.substring(0, slash),
    name: trimmed.substring(slash + 1),
  );
}

Future<Map<String, dynamic>?> _runRepoGraphQl(
  String targetDir,
  ({String owner, String name}) slug,
  String query,
  OrientCommandRunner runCmd,
) async {
  try {
    final out = await runCmd('gh', [
      'api',
      'graphql',
      '-F',
      'owner=${slug.owner}',
      '-F',
      'name=${slug.name}',
      '-f',
      'query=$query',
    ], workingDirectory: targetDir);
    final decoded = jsonDecode(out);
    if (decoded is! Map<String, dynamic>) return null;
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) return null;
    final repo = data['repository'];
    return repo is Map<String, dynamic> ? repo : null;
  } catch (_) {
    return null;
  }
}

Future<({List<_CandidateEntry> docs, List<_CandidateEntry> skills})>
_scanRemoteSites(
  String targetDir,
  ({String owner, String name}) slug,
  List<String> siteNames,
  OrientCommandRunner runCmd,
) async {
  final docs = <_CandidateEntry>[];
  final skills = <_CandidateEntry>[];

  for (
    var offset = 0;
    offset < siteNames.length;
    offset += _remoteSitesBatchSize
  ) {
    final end = (offset + _remoteSitesBatchSize).clamp(0, siteNames.length);
    final batch = siteNames.sublist(offset, end);
    final repoMap = await _runRepoGraphQl(
      targetDir,
      slug,
      _buildRemoteSitesQuery(batch),
      runCmd,
    );
    if (repoMap == null) continue;
    for (var i = 0; i < batch.length; i++) {
      final prefix = 'sites/${batch[i]}';
      docs
        ..addAll(_remoteTreeDocCandidates(repoMap['s${i}Root'], prefix))
        ..addAll(
          _remoteRuleBlobs(repoMap['s${i}Rules'], '$prefix/.agents/rules'),
        );
      skills.addAll(
        _remoteSkills(repoMap['s${i}Skills'], '$prefix/.agents/skills'),
      );
    }
  }
  return (docs: docs, skills: skills);
}

String _buildRemoteSitesQuery(List<String> batch) {
  final fields = StringBuffer();
  for (var i = 0; i < batch.length; i++) {
    final s = batch[i];
    fields
      ..writeln(
        's${i}Root: object(expression: "HEAD:sites/$s") { '
        '... on Tree { entries { name type mode '
        'object { ... on Blob { isBinary text } } } } }',
      )
      ..writeln(
        's${i}Rules: object(expression: "HEAD:sites/$s/.agents/rules") { '
        '... on Tree { entries { name type mode '
        'object { ... on Blob { isBinary text } } } } }',
      )
      ..writeln(
        's${i}Skills: object(expression: "HEAD:sites/$s/.agents/skills") { '
        '... on Tree { entries { name type mode object { ... on Tree { '
        'entries { name type mode object { ... on Blob { isBinary text } } } '
        '} } } } }',
      );
  }
  return 'query(\$owner: String!, \$name: String!) { '
      'repository(owner: \$owner, name: \$name) {\n$fields} }';
}

List<Map<String, dynamic>> _treeEntries(Object? treeObj) {
  if (treeObj is! Map<String, dynamic>) return const [];
  final entries = treeObj['entries'];
  if (entries is! List<dynamic>) return const [];
  return entries.whereType<Map<String, dynamic>>().toList();
}

List<_CandidateEntry> _remoteRootDocs(Map<String, dynamic> repoMap) {
  final modes = <String, int?>{
    for (final e in _treeEntries(repoMap['root']))
      if (e['type'] == 'blob' && e['name'] is String)
        e['name'] as String: e['mode'] as int?,
  };
  const blobAliases = {
    'AGENTS.md': 'agentsMd',
    'CLAUDE.md': 'claudeMd',
    'GEMINI.md': 'geminiMd',
  };
  final out = <_CandidateEntry>[];
  for (final entry in blobAliases.entries) {
    if (!modes.containsKey(entry.key)) continue;
    final mode = modes[entry.key];
    final text = _blobText(repoMap[entry.value]);
    out.add(_remoteCandidate('', entry.key, mode: mode, blobText: text));
  }
  return out;
}

List<_CandidateEntry> _remoteTreeDocCandidates(Object? treeObj, String prefix) {
  final byName = <String, Map<String, dynamic>>{
    for (final e in _treeEntries(treeObj))
      if (e['type'] == 'blob' && e['name'] is String) e['name'] as String: e,
  };
  return [
    for (final name in _nestedDocCandidates)
      if (byName[name] case final e?)
        _remoteCandidate(
          prefix,
          name,
          mode: e['mode'] as int?,
          blobText: _blobText(e['object']),
        ),
  ];
}

List<_CandidateEntry> _remoteNamedDoc(
  Object? treeObj,
  String dirPrefix,
  String blobName,
) {
  for (final e in _treeEntries(treeObj)) {
    if (e['name'] == blobName && e['type'] == 'blob') {
      return [
        _remoteCandidate(
          dirPrefix,
          blobName,
          mode: e['mode'] as int?,
          blobText: _blobText(e['object']),
        ),
      ];
    }
  }
  return const [];
}

List<_CandidateEntry> _remoteRuleBlobs(Object? treeObj, String prefix) {
  final entries = [
    for (final e in _treeEntries(treeObj))
      if (e['type'] == 'blob' &&
          e['name'] is String &&
          (e['name'] as String).endsWith('.md') &&
          (e['name'] as String).toUpperCase() != 'README.MD')
        e,
  ]..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  return [
    for (final e in entries)
      _remoteCandidate(
        prefix,
        e['name'] as String,
        mode: e['mode'] as int?,
        blobText: _blobText(e['object']),
      ),
  ];
}

List<_CandidateEntry> _remoteSkills(Object? treeObj, String prefix) {
  final entries = [
    for (final e in _treeEntries(treeObj))
      if (e['type'] == 'tree' && e['name'] is String) e,
  ]..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  final out = <_CandidateEntry>[];
  for (final e in entries) {
    final skillName = e['name'] as String;
    final skillEntry = _findRemoteBlobEntry(e['object'], 'SKILL.md');
    if (skillEntry == null) continue;
    final text = _blobText(skillEntry['object']);
    final candidate = _remoteCandidate(
      '$prefix/$skillName',
      'SKILL.md',
      mode: skillEntry['mode'] as int?,
      blobText: text,
      summary: text != null ? extractSkillSummary(text) : null,
    );
    out.add(candidate);
  }
  return out;
}

Map<String, dynamic>? _findRemoteBlobEntry(Object? treeObj, String blobName) {
  for (final e in _treeEntries(treeObj)) {
    if (e['name'] == blobName && e['type'] == 'blob') return e;
  }
  return null;
}

String? _blobText(Object? blobObj) {
  if (blobObj is! Map<String, dynamic>) return null;
  if (blobObj['isBinary'] == true) return null;
  final text = blobObj['text'];
  return text is String ? text : null;
}

_CandidateEntry _remoteCandidate(
  String dirPrefix,
  String fileName, {
  required int? mode,
  required String? blobText,
  String? summary,
}) {
  final displayPath = _joinDisplayPath(dirPrefix, fileName);
  final isSymlink = mode == _gitSymlinkMode;
  final canonicalKey =
      isSymlink && blobText != null && blobText.trim().isNotEmpty
      ? p.posix.normalize(
          dirPrefix.isEmpty
              ? blobText.trim()
              : p.posix.join(dirPrefix, blobText.trim()),
        )
      : displayPath;
  return (
    displayPath: displayPath,
    canonicalKey: canonicalKey,
    isSymlink: isSymlink,
    summary: isSymlink ? null : summary,
  );
}

List<String> _extractSafeSubtreeNames(Object? treeObj) => [
  for (final e in _treeEntries(treeObj))
    if (e['type'] == 'tree' &&
        e['name'] is String &&
        _safeSegmentPattern.hasMatch(e['name'] as String))
      e['name'] as String,
]..sort();
