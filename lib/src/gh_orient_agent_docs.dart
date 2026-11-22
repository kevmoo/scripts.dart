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

final _safeSegmentPattern = RegExp(r'^[a-zA-Z0-9._-]+$');

/// Discovered repository-level agent instruction files and skill manifests.
class DiscoveredAgentSetup {
  final List<String> agentDocs;
  final List<String> agentSkills;

  const new({this.agentDocs = const [], this.agentSkills = const []});
}

/// Scans a local repository checkout at [targetDir] for agent instructions and
/// skill manifests, deduplicating symlink aliases (such as `.claude/skills ->
/// ../.agents/skills` or `CLAUDE.md -> AGENTS.md`).
DiscoveredAgentSetup scanLocalAgentSetup(String targetDir) {
  final docs = <String>[];
  final skills = <String>[];
  final seenDocs = <String>{};
  final seenSkills = <String>{};

  _scanDocCandidates(targetDir, '', _rootDocCandidates, seenDocs, docs);
  for (final ruleDir in _ruleDirCandidates) {
    _scanLocalRuleDir(p.join(targetDir, ruleDir), ruleDir, seenDocs, docs);
  }
  for (final skillDir in _skillDirCandidates) {
    _scanLocalSkillDir(
      p.join(targetDir, skillDir),
      skillDir,
      seenSkills,
      skills,
    );
  }

  for (final site in _listChildDirectoryNames(p.join(targetDir, 'sites'))) {
    final sitePrefix = 'sites/$site';
    final sitePath = p.join(targetDir, 'sites', site);
    _scanDocCandidates(
      sitePath,
      sitePrefix,
      _nestedDocCandidates,
      seenDocs,
      docs,
    );
    _scanLocalRuleDir(
      p.join(sitePath, '.agents', 'rules'),
      '$sitePrefix/.agents/rules',
      seenDocs,
      docs,
    );
    _scanLocalSkillDir(
      p.join(sitePath, '.agents', 'skills'),
      '$sitePrefix/.agents/skills',
      seenSkills,
      skills,
    );
  }

  return DiscoveredAgentSetup(agentDocs: docs, agentSkills: skills);
}

/// Scans a monorepo directory at [targetDir] (and ancestor directories up to
/// the `google3` root) for agent instructions and local skill manifests.
DiscoveredAgentSetup scanGoogle3AgentSetup(String targetDir) {
  final docs = <String>[];
  final skills = <String>[];
  final seenDocs = <String>{};
  final seenSkills = <String>{};
  final google3Root = _findGoogle3Root(targetDir);

  Directory? curr = Directory(targetDir);
  while (curr != null && curr.path != curr.parent.path) {
    final prefix = _google3DisplayPrefix(curr.path, targetDir, google3Root);
    _scanDocCandidates(curr.path, prefix, _nestedDocCandidates, seenDocs, docs);
    if (google3Root != null && p.equals(curr.path, google3Root)) break;
    curr = curr.parent;
  }

  for (final ruleDir in const ['_agents/rules', '.agents/rules']) {
    _scanLocalRuleDir(p.join(targetDir, ruleDir), ruleDir, seenDocs, docs);
  }
  for (final skillDir in const ['_agents/skills', '.agents/skills', 'skills']) {
    _scanLocalSkillDir(
      p.join(targetDir, skillDir),
      skillDir,
      seenSkills,
      skills,
    );
  }

  return DiscoveredAgentSetup(agentDocs: docs, agentSkills: skills);
}

String? _findGoogle3Root(String targetDir) {
  Directory? curr = Directory(targetDir);
  while (curr != null && curr.path != curr.parent.path) {
    if (p.basename(curr.path) == 'google3') return curr.path;
    final child = Directory(p.join(curr.path, 'google3'));
    if (child.existsSync()) return child.path;
    curr = curr.parent;
  }
  return null;
}

String _google3DisplayPrefix(
  String dirPath,
  String targetDir,
  String? google3Root,
) {
  if (p.equals(dirPath, targetDir)) return '';
  if (google3Root != null && p.isWithin(google3Root, dirPath)) {
    final rel = p.posix.joinAll(
      p.split(p.relative(dirPath, from: google3Root)),
    );
    return '//$rel';
  }
  if (google3Root != null && p.equals(dirPath, google3Root)) return '//';
  return p.posix.joinAll(p.split(dirPath));
}

void _scanDocCandidates(
  String baseDir,
  String relPrefix,
  List<String> candidates,
  Set<String> seenRealPaths,
  List<String> out,
) {
  for (final rel in candidates) {
    final file = File(p.joinAll([baseDir, ...rel.split('/')]));
    final display = _joinDisplayPath(relPrefix, rel);
    _addUniqueFile(file, display, seenRealPaths, out);
  }
}

String _joinDisplayPath(String prefix, String rel) {
  if (prefix.isEmpty) return rel;
  if (prefix == '//') return '//$rel';
  return '$prefix/$rel';
}

void _scanLocalRuleDir(
  String dirPath,
  String relPrefix,
  Set<String> seenRealPaths,
  List<String> out,
) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return;
  final names = _listMarkdownRuleFiles(dir);
  for (final name in names) {
    _addUniqueFile(
      File(p.join(dirPath, name)),
      '$relPrefix/$name',
      seenRealPaths,
      out,
    );
  }
}

void _scanLocalSkillDir(
  String dirPath,
  String relPrefix,
  Set<String> seenRealPaths,
  List<String> out,
) {
  for (final skillName in _listChildDirectoryNames(dirPath)) {
    final skillFile = File(p.join(dirPath, skillName, 'SKILL.md'));
    _addUniqueFile(
      skillFile,
      '$relPrefix/$skillName/SKILL.md',
      seenRealPaths,
      out,
    );
  }
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

void _addUniqueFile(
  File file,
  String displayPath,
  Set<String> seenRealPaths,
  List<String> out,
) {
  try {
    if (!file.existsSync()) return;
    final resolved = file.resolveSymbolicLinksSync();
    if (seenRealPaths.add(resolved)) {
      out.add(displayPath);
    }
  } on FileSystemException {
    // Skip broken symlinks or unreadable entries.
  }
}

const _remoteAgentSetupGraphQl = r'''
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    root: object(expression: "HEAD:") {
      ... on Tree { entries { name type mode } }
    }
    dotGemini: object(expression: "HEAD:.gemini") {
      ... on Tree { entries { name type mode } }
    }
    dotGithub: object(expression: "HEAD:.github") {
      ... on Tree { entries { name type mode } }
    }
    agentsRules: object(expression: "HEAD:.agents/rules") {
      ... on Tree { entries { name type mode } }
    }
    claudeRules: object(expression: "HEAD:.claude/rules") {
      ... on Tree { entries { name type mode } }
    }
    geminiRules: object(expression: "HEAD:.gemini/rules") {
      ... on Tree { entries { name type mode } }
    }
    githubInstructions: object(expression: "HEAD:.github/instructions") {
      ... on Tree { entries { name type mode } }
    }
    agentsSkills: object(expression: "HEAD:.agents/skills") {
      ... on Tree {
        entries {
          name
          type
          object { ... on Tree { entries { name type } } }
        }
      }
    }
    claudeSkills: object(expression: "HEAD:.claude/skills") {
      ... on Tree {
        entries {
          name
          type
          object { ... on Tree { entries { name type } } }
        }
      }
    }
    geminiSkills: object(expression: "HEAD:.gemini/skills") {
      ... on Tree {
        entries {
          name
          type
          object { ... on Tree { entries { name type } } }
        }
      }
    }
    rootSkills: object(expression: "HEAD:skills") {
      ... on Tree {
        entries {
          name
          type
          object { ... on Tree { entries { name type } } }
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
  OrientCommandRunner runCmd,
) async {
  final slash = remoteRepo.indexOf('/');
  if (slash <= 0 || slash == remoteRepo.length - 1) {
    return const DiscoveredAgentSetup();
  }
  final owner = remoteRepo.substring(0, slash);
  final name = remoteRepo.substring(slash + 1);

  final repoMap = await _runRepoGraphQl(
    targetDir,
    owner,
    name,
    _remoteAgentSetupGraphQl,
    runCmd,
  );
  if (repoMap == null) return const DiscoveredAgentSetup();

  final docs = <String>[];
  final skills = <String>[];

  _collectRemoteDocCandidates(repoMap['root'], '', _nestedDocCandidates, docs);
  if (_hasRemoteBlob(repoMap['dotGemini'], 'styleguide.md')) {
    docs.add('.gemini/styleguide.md');
  }
  if (_hasRemoteBlob(repoMap['dotGithub'], 'copilot-instructions.md')) {
    docs.add('.github/copilot-instructions.md');
  }

  _collectRemoteRuleBlobs(repoMap['agentsRules'], '.agents/rules', docs);
  _collectRemoteRuleBlobs(repoMap['claudeRules'], '.claude/rules', docs);
  _collectRemoteRuleBlobs(repoMap['geminiRules'], '.gemini/rules', docs);
  _collectRemoteRuleBlobs(
    repoMap['githubInstructions'],
    '.github/instructions',
    docs,
  );

  _collectRemoteSkills(repoMap['agentsSkills'], '.agents/skills', skills);
  _collectRemoteSkills(repoMap['claudeSkills'], '.claude/skills', skills);
  _collectRemoteSkills(repoMap['geminiSkills'], '.gemini/skills', skills);
  _collectRemoteSkills(repoMap['rootSkills'], 'skills', skills);

  final siteNames = _extractSafeSubtreeNames(repoMap['sites']);
  if (siteNames.isNotEmpty) {
    await _scanRemoteSites(
      targetDir,
      owner,
      name,
      siteNames,
      runCmd,
      docs,
      skills,
    );
  }

  return DiscoveredAgentSetup(agentDocs: docs, agentSkills: skills);
}

Future<Map<String, dynamic>?> _runRepoGraphQl(
  String targetDir,
  String owner,
  String name,
  String query,
  OrientCommandRunner runCmd,
) async {
  try {
    final out = await runCmd('gh', [
      'api',
      'graphql',
      '-F',
      'owner=$owner',
      '-F',
      'name=$name',
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

Future<void> _scanRemoteSites(
  String targetDir,
  String owner,
  String name,
  List<String> siteNames,
  OrientCommandRunner runCmd,
  List<String> docs,
  List<String> skills,
) async {
  final fields = StringBuffer();
  for (var i = 0; i < siteNames.length; i++) {
    final s = siteNames[i];
    fields
      ..writeln(
        's${i}Root: object(expression: "HEAD:sites/$s") '
        '{ ... on Tree { entries { name type mode } } }',
      )
      ..writeln(
        's${i}Rules: object(expression: "HEAD:sites/$s/.agents/rules") '
        '{ ... on Tree { entries { name type mode } } }',
      )
      ..writeln(
        's${i}Skills: object(expression: "HEAD:sites/$s/.agents/skills") { '
        '... on Tree { entries { name type object { ... on Tree { '
        'entries { name type } } } } } }',
      );
  }
  final query =
      'query(\$owner: String!, \$name: String!) { '
      'repository(owner: \$owner, name: \$name) {\n$fields} }';
  final repoMap = await _runRepoGraphQl(targetDir, owner, name, query, runCmd);
  if (repoMap == null) return;

  for (var i = 0; i < siteNames.length; i++) {
    final prefix = 'sites/${siteNames[i]}';
    _collectRemoteDocCandidates(
      repoMap['s${i}Root'],
      prefix,
      _nestedDocCandidates,
      docs,
    );
    _collectRemoteRuleBlobs(
      repoMap['s${i}Rules'],
      '$prefix/.agents/rules',
      docs,
    );
    _collectRemoteSkills(
      repoMap['s${i}Skills'],
      '$prefix/.agents/skills',
      skills,
    );
  }
}

List<Map<String, dynamic>> _treeEntries(Object? treeObj) {
  if (treeObj is! Map<String, dynamic>) return const [];
  final entries = treeObj['entries'];
  if (entries is! List<dynamic>) return const [];
  return entries.whereType<Map<String, dynamic>>().toList();
}

void _collectRemoteDocCandidates(
  Object? treeObj,
  String prefix,
  List<String> candidates,
  List<String> out,
) {
  final byName = <String, Map<String, dynamic>>{
    for (final e in _treeEntries(treeObj))
      if (e['type'] == 'blob' && e['name'] is String) e['name'] as String: e,
  };
  var hasRegularDoc = false;
  for (final name in candidates) {
    final entry = byName[name];
    if (entry == null) continue;
    final isSymlink = entry['mode'] == _gitSymlinkMode;
    if (isSymlink && hasRegularDoc) continue;
    if (!isSymlink) hasRegularDoc = true;
    out.add(_joinDisplayPath(prefix, name));
  }
}

bool _hasRemoteBlob(Object? treeObj, String blobName) =>
    _treeEntries(treeObj)
        .any((e) => e['name'] == blobName && e['type'] == 'blob');

void _collectRemoteRuleBlobs(Object? treeObj, String prefix, List<String> out) {
  final names = <String>[
    for (final e in _treeEntries(treeObj))
      if (e['type'] == 'blob' &&
          e['name'] is String &&
          (e['name'] as String).endsWith('.md') &&
          (e['name'] as String).toUpperCase() != 'README.MD')
        e['name'] as String,
  ]..sort();
  for (final name in names) {
    out.add('$prefix/$name');
  }
}

void _collectRemoteSkills(Object? treeObj, String prefix, List<String> out) {
  final names = <String>[
    for (final e in _treeEntries(treeObj))
      if (e['type'] == 'tree' &&
          e['name'] is String &&
          _hasRemoteBlob(e['object'], 'SKILL.md'))
        e['name'] as String,
  ]..sort();
  for (final name in names) {
    out.add('$prefix/$name/SKILL.md');
  }
}

List<String> _extractSafeSubtreeNames(Object? treeObj) => [
  for (final e in _treeEntries(treeObj))
    if (e['type'] == 'tree' &&
        e['name'] is String &&
        _safeSegmentPattern.hasMatch(e['name'] as String))
      e['name'] as String,
]..sort();
