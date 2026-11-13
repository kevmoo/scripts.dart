import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../process_utils.dart';
import '../shared/graphql_utils.dart';

const _repoBatchSize = 10;

/// Snapshot of remote GitHub settings and `HEAD` files for a single repository.
final class RemoteRepoSnapshot {
  final String name;
  final bool isArchived;
  final bool isFork;
  final bool isPrivate;
  final String defaultBranch;
  final bool autoMergeAllowed;
  final bool hasAutosubmitLabel;
  final bool hasRulesetOrProtection;
  final List<String> requiredChecks;
  final String? defaultBranchRulesetId;
  final List<String> defaultBranchRequiredChecks;

  // Root HEAD files & trees
  final String? rootPubspecText;
  final String? analysisOptionsText;
  final bool hasPrettierRc;
  final bool hasPrettierIgnore;
  final String? dependabotText;
  final bool hasRootApiTxt;
  final bool hasRootApiTest;
  final bool hasRootLibOrBin;
  final bool hasSkillsMarkdown;
  final Map<String, String> workflowFiles;
  final List<String> packageSubdirNames;
  final Map<String, RemotePackageBlobInfo> subPackages;

  const new({
    required this.name,
    required this.isArchived,
    required this.isFork,
    required this.isPrivate,
    required this.defaultBranch,
    required this.autoMergeAllowed,
    required this.hasAutosubmitLabel,
    required this.hasRulesetOrProtection,
    required this.requiredChecks,
    required this.defaultBranchRulesetId,
    required this.defaultBranchRequiredChecks,
    required this.rootPubspecText,
    required this.analysisOptionsText,
    required this.hasPrettierRc,
    required this.hasPrettierIgnore,
    required this.dependabotText,
    required this.hasRootApiTxt,
    required this.hasRootApiTest,
    required this.hasRootLibOrBin,
    required this.hasSkillsMarkdown,
    required this.workflowFiles,
    this.packageSubdirNames = const [],
    required this.subPackages,
  });

  RemoteRepoSnapshot withSubPackages(
    Map<String, RemotePackageBlobInfo> merged,
  ) => RemoteRepoSnapshot(
    name: name,
    isArchived: isArchived,
    isFork: isFork,
    isPrivate: isPrivate,
    defaultBranch: defaultBranch,
    autoMergeAllowed: autoMergeAllowed,
    hasAutosubmitLabel: hasAutosubmitLabel,
    hasRulesetOrProtection: hasRulesetOrProtection,
    requiredChecks: requiredChecks,
    defaultBranchRulesetId: defaultBranchRulesetId,
    defaultBranchRequiredChecks: defaultBranchRequiredChecks,
    rootPubspecText: rootPubspecText,
    analysisOptionsText: analysisOptionsText,
    hasPrettierRc: hasPrettierRc,
    hasPrettierIgnore: hasPrettierIgnore,
    dependabotText: dependabotText,
    hasRootApiTxt: hasRootApiTxt,
    hasRootApiTest: hasRootApiTest,
    hasRootLibOrBin: hasRootLibOrBin,
    hasSkillsMarkdown: hasSkillsMarkdown,
    workflowFiles: workflowFiles,
    packageSubdirNames: packageSubdirNames,
    subPackages: merged,
  );
}

/// Package metadata blobs for a workspace member or `packages/*` subdirectory.
typedef RemotePackageBlobInfo = ({
  String? pubspecText,
  bool hasApiTxt,
  bool hasApiTest,
});

/// Fetches non-archived, non-fork repository names owned by [owner] via
/// paginated GitHub GraphQL.
List<String> fetchOwnerActiveCandidateRepos(
  String owner, {
  SyncProcessRunner runner = defaultSyncProcessRunner,
}) {
  final names = <String>[];
  String? cursor;

  while (true) {
    final data = _executeGraphQL(
      runner,
      _ownerReposQuery,
      variables: {'owner': owner, 'cursor': ?cursor},
    );
    final page = _extractOwnerReposPage(data, names);
    if (!page.hasNext || page.cursor == null) break;
    cursor = page.cursor;
  }

  names.sort();
  return names;
}

/// Asynchronous counterpart to [fetchOwnerActiveCandidateRepos].
Future<List<String>> fetchOwnerActiveCandidateReposAsync(
  String owner, {
  ProcessRunner runner = defaultProcessRunner,
}) async {
  final names = <String>[];
  String? cursor;

  while (true) {
    final data = await _executeGraphQLAsync(
      runner,
      _ownerReposQuery,
      variables: {'owner': owner, 'cursor': ?cursor},
    );
    final page = _extractOwnerReposPage(data, names);
    if (!page.hasNext || page.cursor == null) break;
    cursor = page.cursor;
  }

  names.sort();
  return names;
}

({bool hasNext, String? cursor}) _extractOwnerReposPage(
  Map<String, dynamic>? data,
  List<String> names,
) {
  final ownerMap = data?['repositoryOwner'] as Map<String, dynamic>?;
  final repos = ownerMap?['repositories'] as Map<String, dynamic>?;
  if (repos == null) return (hasNext: false, cursor: null);

  for (final node
      in (repos['nodes'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()) {
    final isArchived = node['isArchived'] == true;
    final isFork = node['isFork'] == true;
    final name = node['name'] as String?;
    if (!isArchived && !isFork && name != null) {
      names.add(name);
    }
  }

  final pageInfo = repos['pageInfo'] as Map<String, dynamic>?;
  return (
    hasNext: pageInfo?['hasNextPage'] == true,
    cursor: pageInfo?['endCursor'] as String?,
  );
}

/// Asynchronous counterpart to [fetchRemoteRepoSnapshots] that executes all
/// repository GraphQL chunks concurrently.
Future<Map<String, RemoteRepoSnapshot>> fetchRemoteRepoSnapshotsAsync(
  String owner,
  List<String> repoNames, {
  ProcessRunner runner = defaultProcessRunner,
  bool Function(Map<String, dynamic> ruleset, String defaultBranch)?
  targetsBranchPredicate,
}) async {
  if (repoNames.isEmpty) return const {};

  final chunks = <List<String>>[
    for (var i = 0; i < repoNames.length; i += _repoBatchSize)
      repoNames.sublist(
        i,
        i + _repoBatchSize > repoNames.length
            ? repoNames.length
            : i + _repoBatchSize,
      ),
  ];

  final chunkData = await Future.wait(
    chunks.map(
      (c) => _executeGraphQLAsync(runner, _buildBatchReposQuery(owner, c)),
    ),
  );

  final snapshots = <String, RemoteRepoSnapshot>{};
  for (var i = 0; i < chunks.length; i++) {
    final data = chunkData[i];
    if (data == null) continue;
    final chunk = chunks[i];
    for (var j = 0; j < chunk.length; j++) {
      final node = data['r$j'];
      if (node is Map<String, dynamic>) {
        final snap = _parseRepoNode(
          node,
          targetsBranchPredicate: targetsBranchPredicate,
        );
        snapshots[snap.name] = snap;
      }
    }
  }

  await _populateWorkspaceMembersAsync(owner, snapshots, runner: runner);
  return snapshots;
}

Future<void> _populateWorkspaceMembersAsync(
  String owner,
  Map<String, RemoteRepoSnapshot> snapshots, {
  required ProcessRunner runner,
}) async {
  final requests = _collectPendingMemberRequests(snapshots);
  if (requests.isEmpty) return;

  const memberBatchSize = 20;
  final chunks = <List<({String repo, String member})>>[
    for (var i = 0; i < requests.length; i += memberBatchSize)
      requests.sublist(
        i,
        i + memberBatchSize > requests.length
            ? requests.length
            : i + memberBatchSize,
      ),
  ];

  final responses = await Future.wait(
    chunks.map(
      (c) => _executeGraphQLAsync(
        runner,
        _buildWorkspaceMemberBatchQuery(owner, c),
      ),
    ),
  );

  final fetchedByRepo = <String, Map<String, RemotePackageBlobInfo>>{};
  for (var i = 0; i < chunks.length; i++) {
    final data = responses[i];
    if (data != null) {
      _collectWorkspaceMemberBatch(chunks[i], data, fetchedByRepo);
    }
  }
  _mergeFetchedSubPackages(snapshots, fetchedByRepo);
}

List<({String repo, String member})> _collectPendingMemberRequests(
  Map<String, RemoteRepoSnapshot> snapshots,
) {
  final requests = <({String repo, String member})>[];
  for (final snap in snapshots.values) {
    final pubText = snap.rootPubspecText;
    if (pubText == null) continue;
    final wsMembers = _extractWorkspaceMembers(pubText);
    final candidates = wsMembers.isNotEmpty
        ? wsMembers
        : snap.packageSubdirNames.map((d) => 'packages/$d');
    for (final member in candidates) {
      if (!snap.subPackages.containsKey(member)) {
        requests.add((repo: snap.name, member: member));
      }
    }
  }
  return requests;
}

void _mergeFetchedSubPackages(
  Map<String, RemoteRepoSnapshot> snapshots,
  Map<String, Map<String, RemotePackageBlobInfo>> fetchedByRepo,
) {
  for (final MapEntry(key: repoName, value: extraPkgs)
      in fetchedByRepo.entries) {
    final existing = snapshots[repoName];
    if (existing != null) {
      snapshots[repoName] = existing.withSubPackages({
        ...existing.subPackages,
        ...extraPkgs,
      });
    }
  }
}

/// Batch-fetches [RemoteRepoSnapshot]s for [repoNames] under [owner] in minimal
/// GitHub GraphQL round-trips.
Map<String, RemoteRepoSnapshot> fetchRemoteRepoSnapshots(
  String owner,
  List<String> repoNames, {
  SyncProcessRunner runner = defaultSyncProcessRunner,
  bool Function(Map<String, dynamic> ruleset, String defaultBranch)?
  targetsBranchPredicate,
}) {
  if (repoNames.isEmpty) return const {};

  final snapshots = <String, RemoteRepoSnapshot>{};
  for (var i = 0; i < repoNames.length; i += _repoBatchSize) {
    final chunk = repoNames.sublist(
      i,
      i + _repoBatchSize > repoNames.length
          ? repoNames.length
          : i + _repoBatchSize,
    );
    final query = _buildBatchReposQuery(owner, chunk);
    final data = _executeGraphQL(runner, query);
    if (data == null) continue;

    for (var j = 0; j < chunk.length; j++) {
      final node = data['r$j'];
      if (node is Map<String, dynamic>) {
        final snap = _parseRepoNode(
          node,
          targetsBranchPredicate: targetsBranchPredicate,
        );
        snapshots[snap.name] = snap;
      }
    }
  }

  _populateWorkspaceMembers(owner, snapshots, runner: runner);
  return snapshots;
}

void _populateWorkspaceMembers(
  String owner,
  Map<String, RemoteRepoSnapshot> snapshots, {
  required SyncProcessRunner runner,
}) {
  final requests = _collectPendingMemberRequests(snapshots);
  if (requests.isEmpty) return;

  const memberBatchSize = 25;
  final fetchedByRepo = <String, Map<String, RemotePackageBlobInfo>>{};
  for (var i = 0; i < requests.length; i += memberBatchSize) {
    final chunk = requests.sublist(
      i,
      i + memberBatchSize > requests.length
          ? requests.length
          : i + memberBatchSize,
    );
    final data = _executeGraphQL(
      runner,
      _buildWorkspaceMemberBatchQuery(owner, chunk),
    );
    if (data == null) continue;
    _collectWorkspaceMemberBatch(chunk, data, fetchedByRepo);
  }
  _mergeFetchedSubPackages(snapshots, fetchedByRepo);
}

void _collectWorkspaceMemberBatch(
  List<({String repo, String member})> chunk,
  Map<String, dynamic> data,
  Map<String, Map<String, RemotePackageBlobInfo>> fetchedByRepo,
) {
  for (var j = 0; j < chunk.length; j++) {
    final node = data['m$j'];
    if (node is! Map<String, dynamic>) continue;
    final req = chunk[j];
    fetchedByRepo.putIfAbsent(req.repo, () => {})[req.member] = (
      pubspecText: _blobText(node['pubspec']),
      hasApiTxt: node['apiTxt'] != null,
      hasApiTest: node['apiTest'] != null,
    );
  }
}

List<String> _extractWorkspaceMembers(String rootPubspecText) {
  try {
    final doc = loadYaml(rootPubspecText);
    final ws = doc is YamlMap ? doc['workspace'] : null;
    if (ws is YamlList) {
      return ws
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
  } catch (_) {}
  return const [];
}

Future<Map<String, dynamic>?> _executeGraphQLAsync(
  ProcessRunner runner,
  String query, {
  Map<String, String> variables = const {},
}) async {
  final args = <String>[
    'api',
    'graphql',
    '-f',
    'query=$query',
    for (final MapEntry(:key, :value) in variables.entries) ...[
      '-F',
      '$key=$value',
    ],
  ];
  final res = await runGhWithRetry(runner, args);
  if (res.exitCode != 0) return null;
  try {
    final decoded = jsonDecode(res.stdout.toString());
    if (decoded is Map<String, dynamic>) {
      return decoded['data'] as Map<String, dynamic>?;
    }
  } catch (_) {}
  return null;
}

Map<String, dynamic>? _executeGraphQL(
  SyncProcessRunner runner,
  String query, {
  Map<String, String> variables = const {},
}) {
  final args = <String>[
    'api',
    'graphql',
    '-f',
    'query=$query',
    for (final MapEntry(:key, :value) in variables.entries) ...[
      '-F',
      '$key=$value',
    ],
  ];
  final res = runGhWithRetrySync(runner, args);
  if (res.exitCode != 0) return null;
  try {
    final decoded = jsonDecode(res.stdout.toString());
    if (decoded is Map<String, dynamic>) {
      return decoded['data'] as Map<String, dynamic>?;
    }
  } catch (_) {}
  return null;
}

String _buildBatchReposQuery(String owner, List<String> chunk) {
  final escapedOwner = jsonEncode(owner);
  final buf = StringBuffer('query {\n');
  for (var i = 0; i < chunk.length; i++) {
    final escapedRepo = jsonEncode(chunk[i]);
    buf.writeln(
      '  r$i: repository(owner: $escapedOwner, name: $escapedRepo) '
      '{ ...RepoFields }',
    );
  }
  buf
    ..writeln('}')
    ..writeln(_repoFieldsFragment);
  return buf.toString();
}

String _buildWorkspaceMemberBatchQuery(
  String owner,
  List<({String repo, String member})> chunk,
) {
  final escapedOwner = jsonEncode(owner);
  final buf = StringBuffer('query {\n');
  for (var i = 0; i < chunk.length; i++) {
    final item = chunk[i];
    final escapedRepo = jsonEncode(item.repo);
    final pubExpr = jsonEncode('HEAD:${item.member}/pubspec.yaml');
    final apiExpr = jsonEncode('HEAD:${item.member}/api.txt');
    final testExpr = jsonEncode('HEAD:${item.member}/test/api_test.dart');
    buf.writeln('''
  m$i: repository(owner: $escapedOwner, name: $escapedRepo) {
    pubspec: object(expression: $pubExpr) { ... on Blob { text } }
    apiTxt: object(expression: $apiExpr) { __typename }
    apiTest: object(expression: $testExpr) { __typename }
  }''');
  }
  buf.writeln('}');
  return buf.toString();
}

RemoteRepoSnapshot _parseRepoNode(
  Map<String, dynamic> node, {
  bool Function(Map<String, dynamic> ruleset, String defaultBranch)?
  targetsBranchPredicate,
}) {
  final defaultBranchRef = node['defaultBranchRef'] as Map<String, dynamic>?;
  final defaultBranch = defaultBranchRef?['name']?.toString() ?? 'main';
  final rulesetInfo = _parseGraphQLRulesets(
    node,
    defaultBranch,
    targetsBranchPredicate: targetsBranchPredicate,
  );
  final dependabotText =
      _blobText(node['dependabotYml']) ?? _blobText(node['dependabotYaml']);

  return RemoteRepoSnapshot(
    name: node['name']?.toString() ?? '',
    isArchived: node['isArchived'] == true,
    isFork: node['isFork'] == true,
    isPrivate: node['isPrivate'] == true,
    defaultBranch: defaultBranch,
    autoMergeAllowed: node['autoMergeAllowed'] == true,
    hasAutosubmitLabel: node['autosubmitLabel'] != null,
    hasRulesetOrProtection: rulesetInfo.hasRulesetOrProtection,
    requiredChecks: rulesetInfo.requiredChecks,
    defaultBranchRulesetId: rulesetInfo.defaultBranchRulesetId,
    defaultBranchRequiredChecks: rulesetInfo.defaultBranchRequiredChecks,
    rootPubspecText: _blobText(node['pubspec']),
    analysisOptionsText: _blobText(node['analysisOptions']),
    hasPrettierRc: node['prettierRc'] != null,
    hasPrettierIgnore: node['prettierIgnore'] != null,
    dependabotText: dependabotText,
    hasRootApiTxt: node['apiTxt'] != null,
    hasRootApiTest: node['apiTest'] != null,
    hasRootLibOrBin: node['libDir'] != null || node['binDir'] != null,
    hasSkillsMarkdown: _parseHasSkillsMarkdown(node['skills']),
    workflowFiles: _parseWorkflowTree(node['workflows']),
    packageSubdirNames: _parsePackageSubdirNames(node['packages']),
    subPackages: const {},
  );
}

({
  bool hasRulesetOrProtection,
  List<String> requiredChecks,
  String? defaultBranchRulesetId,
  List<String> defaultBranchRequiredChecks,
})
_parseGraphQLRulesets(
  Map<String, dynamic> repoNode,
  String defaultBranch, {
  bool Function(Map<String, dynamic> ruleset, String defaultBranch)?
  targetsBranchPredicate,
}) {
  final rulesetsConn = repoNode['rulesets'] as Map<String, dynamic>?;
  final rulesetNodes = (rulesetsConn?['nodes'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();

  if (rulesetNodes.isNotEmpty) {
    return _extractFromRulesetNodes(
      rulesetNodes,
      defaultBranch,
      targetsBranchPredicate: targetsBranchPredicate,
    );
  }

  return _extractFromBranchProtection(repoNode);
}

({
  bool hasRulesetOrProtection,
  List<String> requiredChecks,
  String? defaultBranchRulesetId,
  List<String> defaultBranchRequiredChecks,
})
_extractFromRulesetNodes(
  List<Map<String, dynamic>> rulesetNodes,
  String defaultBranch, {
  bool Function(Map<String, dynamic> ruleset, String defaultBranch)?
  targetsBranchPredicate,
}) {
  final allChecks = <String>[];
  final defaultChecks = <String>[];
  String? defaultId;

  for (final rs in rulesetNodes) {
    final normalized = _normalizeGraphQLRuleset(rs);
    final checks = _extractGraphQLRuleChecks(rs);
    allChecks.addAll(checks);

    final matchesBranch =
        targetsBranchPredicate == null ||
        targetsBranchPredicate(normalized, defaultBranch);
    if (defaultId == null && matchesBranch) {
      defaultId = rs['databaseId']?.toString();
      defaultChecks.addAll(checks);
    }
  }

  return (
    hasRulesetOrProtection: true,
    requiredChecks: allChecks,
    defaultBranchRulesetId: defaultId,
    defaultBranchRequiredChecks: defaultChecks,
  );
}

Map<String, dynamic> _normalizeGraphQLRuleset(Map<String, dynamic> rs) {
  final cond = rs['conditions'] as Map<String, dynamic>?;
  final refName = cond?['refName'] as Map<String, dynamic>?;
  return {
    'target': (rs['target']?.toString() ?? '').toLowerCase(),
    'enforcement': (rs['enforcement']?.toString() ?? '').toLowerCase(),
    'conditions': {
      'ref_name': {
        'include': refName?['include'] ?? const <dynamic>[],
        'exclude': refName?['exclude'] ?? const <dynamic>[],
      },
    },
  };
}

List<String> _extractGraphQLRuleChecks(Map<String, dynamic> rs) {
  final rulesConn = rs['rules'] as Map<String, dynamic>?;
  final ruleNodes = (rulesConn?['nodes'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  final checks = <String>[];
  for (final rule in ruleNodes) {
    if (rule['type']?.toString().toUpperCase() != 'REQUIRED_STATUS_CHECKS') {
      continue;
    }
    final params = rule['parameters'] as Map<String, dynamic>?;
    final scList =
        params?['requiredStatusChecks'] as List<dynamic>? ?? const [];
    for (final sc in scList.whereType<Map<String, dynamic>>()) {
      final ctx = sc['context']?.toString();
      if (ctx != null) checks.add(ctx);
    }
  }
  return checks;
}

({
  bool hasRulesetOrProtection,
  List<String> requiredChecks,
  String? defaultBranchRulesetId,
  List<String> defaultBranchRequiredChecks,
})
_extractFromBranchProtection(Map<String, dynamic> repoNode) {
  final bpConn = repoNode['branchProtectionRules'] as Map<String, dynamic>?;
  final bpNodes = (bpConn?['nodes'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  if (bpNodes.isEmpty) {
    return (
      hasRulesetOrProtection: false,
      requiredChecks: const <String>[],
      defaultBranchRulesetId: null,
      defaultBranchRequiredChecks: const <String>[],
    );
  }
  final checks = <String>[
    for (final bp in bpNodes)
      for (final ctx
          in bp['requiredStatusCheckContexts'] as List<dynamic>? ?? const [])
        ctx.toString(),
  ];
  return (
    hasRulesetOrProtection: true,
    requiredChecks: checks,
    defaultBranchRulesetId: null,
    defaultBranchRequiredChecks: checks,
  );
}

String? _blobText(Object? obj) =>
    obj is Map<String, dynamic> ? obj['text'] as String? : null;

bool _parseHasSkillsMarkdown(Object? skillsTree) {
  if (skillsTree is! Map<String, dynamic>) return false;
  final entries = skillsTree['entries'] as List<dynamic>? ?? const [];
  for (final entry in entries.whereType<Map<String, dynamic>>()) {
    final subObj = entry['object'];
    if (subObj is! Map<String, dynamic>) continue;
    final subEntries = subObj['entries'] as List<dynamic>? ?? const [];
    if (subEntries.any(
      (e) => e is Map<String, dynamic> && e['name'] == 'SKILL.md',
    )) {
      return true;
    }
  }
  return false;
}

Map<String, String> _parseWorkflowTree(Object? wfTree) {
  if (wfTree is! Map<String, dynamic>) return const {};
  final entries = wfTree['entries'] as List<dynamic>? ?? const [];
  final map = <String, String>{};
  for (final entry in entries.whereType<Map<String, dynamic>>()) {
    final name = entry['name']?.toString();
    final text = _blobText(entry['object']);
    if (name != null && text != null) {
      map[name] = text;
    }
  }
  return map;
}

List<String> _parsePackageSubdirNames(Object? pkgsTree) {
  if (pkgsTree is! Map<String, dynamic>) return const [];
  final entries = pkgsTree['entries'] as List<dynamic>? ?? const [];
  return [
    for (final e in entries.whereType<Map<String, dynamic>>())
      if (e['type'] == 'tree' && e['name'] != null) e['name'].toString(),
  ];
}

const _ownerReposQuery = r'''
query($owner: String!, $cursor: String) {
  repositoryOwner(login: $owner) {
    repositories(
      first: 100
      after: $cursor
      ownerAffiliations: OWNER
      isFork: false
      isArchived: false
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        isArchived
        isFork
      }
    }
  }
}
''';

const _repoFieldsFragment = '''
fragment RepoFields on Repository {
  name
  isArchived
  isFork
  isPrivate
  autoMergeAllowed
  defaultBranchRef { name }
  autosubmitLabel: label(name: "autosubmit") { name }
  rulesets(first: 10, includeParents: false) {
    nodes {
      databaseId
      name
      target
      enforcement
      conditions {
        refName { include exclude }
      }
      rules(first: 20) {
        nodes {
          type
          parameters {
            ... on RequiredStatusChecksParameters {
              requiredStatusChecks { context }
            }
          }
        }
      }
    }
  }
  branchProtectionRules(first: 5) {
    nodes {
      pattern
      requiredStatusCheckContexts
    }
  }
  pubspec: object(expression: "HEAD:pubspec.yaml") { ... on Blob { text } }
  analysisOptions: object(expression: "HEAD:analysis_options.yaml") {
    ... on Blob { text }
  }
  prettierRc: object(expression: "HEAD:.prettierrc.json") { __typename }
  prettierIgnore: object(expression: "HEAD:.prettierignore") { __typename }
  dependabotYml: object(expression: "HEAD:.github/dependabot.yml") {
    ... on Blob { text }
  }
  dependabotYaml: object(expression: "HEAD:.github/dependabot.yaml") {
    ... on Blob { text }
  }
  apiTxt: object(expression: "HEAD:api.txt") { __typename }
  apiTest: object(expression: "HEAD:test/api_test.dart") { __typename }
  libDir: object(expression: "HEAD:lib") { __typename }
  binDir: object(expression: "HEAD:bin") { __typename }
  workflows: object(expression: "HEAD:.github/workflows") {
    ... on Tree {
      entries {
        name
        object { ... on Blob { text } }
      }
    }
  }
  skills: object(expression: "HEAD:skills") {
    ... on Tree {
      entries {
        name
        object {
          ... on Tree {
            entries { name }
          }
        }
      }
    }
  }
  packages: object(expression: "HEAD:packages") {
    ... on Tree {
      entries { name type }
    }
  }
}
''';
