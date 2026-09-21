import 'dart:convert';
import 'dart:io';

import '../gh_clean.dart';
import '../local_repo_scanner.dart';
import '../process_utils.dart';
import '../shared/graphql_utils.dart';

/// Builds the GraphQL search query for merged PRs.
String buildLandedSearchQuery({
  required String user,
  String? repo,
  int? lastNDays,
  DateTime? now,
}) {
  if (lastNDays != null && lastNDays <= 0) {
    throw ArgumentError.value(
      lastNDays,
      'lastNDays',
      'Must be a positive integer.',
    );
  }

  final buffer = StringBuffer('is:pr is:merged');
  if (user.isNotEmpty) buffer.write(' author:$user');
  if (repo != null && repo.isNotEmpty) buffer.write(' repo:$repo');

  if (lastNDays != null) {
    final reference = now ?? DateTime.now();
    final cutoff = reference.subtract(Duration(days: lastNDays));
    final y = cutoff.year.toString().padLeft(4, '0');
    final m = cutoff.month.toString().padLeft(2, '0');
    final d = cutoff.day.toString().padLeft(2, '0');
    buffer.write(' merged:>=$y-$m-$d');
  }

  buffer.write(' sort:updated-desc');
  return buffer.toString();
}

/// Fetches merged pull requests via GitHub CLI (`gh api graphql`).
Future<List<LandedPr>> fetchLandedPrs({
  required String user,
  String? repo,
  int? lastNDays = 7,
  int limit = 50,
  bool includeOwned = true,
  SyncProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final queryStr = buildLandedSearchQuery(
    user: user,
    repo: repo,
    lastNDays: lastNDays,
  );

  const gqlQuery = r'''
query($q: String!, $limit: Int!, $cursor: String) {
  search(query: $q, type: ISSUE, first: $limit, after: $cursor) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on PullRequest {
        number
        title
        url
        state
        merged
        mergedAt
        closedAt
        headRefName
        headRefOid
        headRef {
          name
        }
        headRepository {
          nameWithOwner
          viewerPermission
        }
        baseRefName
        repository {
          nameWithOwner
          url
          isArchived
        }
        mergeCommit {
          oid
        }
      }
    }
  }
}
''';

  final nodes = paginateGraphQLSearchSync(
    graphqlQuery: gqlQuery,
    searchQuery: queryStr,
    limit: limit,
    runner: runner,
    exceptionBuilder: (message, {exitCode = 1}) =>
        GhCleanException(message, exitCode: exitCode),
  );

  return [
    for (final node in nodes)
      if (parseLandedPrNode(node) case final parsed?)
        if (!isDartSdkRepositoryName(parsed.repository) &&
            _isAllowedUserPr(
              parsed.repository,
              user,
              includeOwned: includeOwned,
            ))
          parsed,
  ];
}

bool _isAllowedUserPr(
  String repository,
  String user, {
  required bool includeOwned,
}) {
  if (includeOwned || user.isEmpty || user == '@me') return true;
  return !repository.toLowerCase().startsWith('${user.toLowerCase()}/');
}

/// Parses a landed PR node from GraphQL.
LandedPr? parseLandedPrNode(Map<String, dynamic> node) {
  final core = GhPrRef.parseCoreFields(node, defaultBaseRefName: 'main');
  if (core == null) return null;

  final mergedAtStr = node['mergedAt'] as String?;
  final mergedAt = mergedAtStr != null ? DateTime.tryParse(mergedAtStr) : null;

  final closedAtStr = node['closedAt'] as String?;
  final closedAt = closedAtStr != null ? DateTime.tryParse(closedAtStr) : null;

  final mergeCommit = node['mergeCommit'] as Map<String, dynamic>?;
  final mergeSha = mergeCommit?['oid'] as String?;

  final headRefExists = node['headRef'] != null;
  final headRepoMap = node['headRepository'] as Map<String, dynamic>?;
  final headRepository = headRepoMap?['nameWithOwner'] as String?;
  final headRepoPermission = headRepoMap?['viewerPermission'] as String?;

  return LandedPr(
    number: core.number,
    title: core.title,
    url: core.url,
    repository: core.repository,
    repoUrl: core.repoUrl,
    headRefName: core.headRefName,
    headRefOid: core.headRefOid,
    baseRefName: core.baseRefName,
    mergeSha: mergeSha,
    mergedAt: mergedAt,
    closedAt: closedAt,
    headRefExists: headRefExists,
    headRepository: headRepository,
    headRepoPermission: headRepoPermission,
  );
}

Iterable<({LocalRepoInfo repo, String owner, String name})> _filteredRootRepos(
  List<LocalRepoInfo> localRepos, {
  String? repoFilter,
}) sync* {
  for (final repo in localRepos) {
    if (!isRootGitRepository(Directory(repo.repoPath))) continue;
    if (!_isRepoMatchingFilter(repo, repoFilter)) continue;
    final parsedRepo = _parseRepoOwnerAndName(repo);
    if (parsedRepo == null) continue;
    yield (repo: repo, owner: parsedRepo.owner, name: parsedRepo.name);
  }
}

bool _isRepoMatchingFilter(LocalRepoInfo repo, String? repoFilter) {
  if (isDartSdkRepositoryName(repo.repoName)) return false;
  if (repoFilter == null) return true;
  return repo.repoNames.any((n) => n.toLowerCase() == repoFilter.toLowerCase());
}

({String owner, String name})? _parseRepoOwnerAndName(LocalRepoInfo repo) {
  final canonicalRepo = repo.repoNames.firstOrNull;
  if (canonicalRepo == null || !canonicalRepo.contains('/')) return null;
  final repoParts = canonicalRepo.split('/');
  return (owner: repoParts[0], name: repoParts[1]);
}

Map<String, dynamic>? _tryParseGraphQLData(Object? stdout) {
  if (stdout is! String || stdout.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(stdout) as Map<String, dynamic>?;
    return decoded?['data'] as Map<String, dynamic>?;
  } catch (_) {
    return null;
  }
}

typedef _CandidateBranch = ({
  LocalRepoInfo repo,
  String branch,
  String owner,
  String name,
});

/// Discovers merged pull requests authored by collaborators or takeovers
/// matching candidate local branches or worktrees.
Future<List<LandedPr>> findCrossAuthorLandedPrs(
  List<LocalRepoInfo> localRepos,
  Set<String> alreadyMatchedBranches, {
  int? lastNDays = 7,
  String? repoFilter,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final candidates = _collectCandidateBranches(
    localRepos,
    alreadyMatchedBranches,
    repoFilter: repoFilter,
  );
  if (candidates.isEmpty) return const [];

  onProgress?.call(
    'Checking ${candidates.length} local candidate branch(es) for '
    'cross-author PRs...',
  );

  return _fetchBatchCrossAuthorPrs(
    candidates,
    runner,
    lastNDays: lastNDays,
    onProgress: onProgress,
  );
}

List<_CandidateBranch> _collectCandidateBranches(
  List<LocalRepoInfo> localRepos,
  Set<String> alreadyMatchedBranches, {
  String? repoFilter,
}) {
  final candidates = <_CandidateBranch>[];
  for (final r in _filteredRootRepos(localRepos, repoFilter: repoFilter)) {
    _collectRepoCandidateBranches(
      r.repo,
      r.owner,
      r.name,
      alreadyMatchedBranches,
      candidates,
    );
  }
  return candidates;
}

void _collectRepoCandidateBranches(
  LocalRepoInfo repo,
  String owner,
  String name,
  Set<String> alreadyMatchedBranches,
  List<_CandidateBranch> candidates,
) {
  final trunk = resolveTrunkBranch(repo);
  final uniqueBranches = <String>{};
  final repoKey = '$owner/$name'.toLowerCase();

  for (final b in repo.branches) {
    if (_isBranchCandidate(b.name, trunk, repoKey, alreadyMatchedBranches)) {
      uniqueBranches.add(b.name);
    }
  }

  for (final wt in repo.worktrees) {
    if (wt.path != repo.repoPath &&
        wt.branch.isNotEmpty &&
        wt.branch != 'DETACHED' &&
        _isBranchCandidate(wt.branch, trunk, repoKey, alreadyMatchedBranches)) {
      uniqueBranches.add(wt.branch);
    }
  }

  for (final branch in uniqueBranches) {
    candidates.add((repo: repo, branch: branch, owner: owner, name: name));
  }
}

bool _isBranchCandidate(
  String branch,
  String trunk,
  String repoKey,
  Set<String> alreadyMatchedBranches,
) {
  if (branch.isEmpty) return false;
  if (branch == trunk || branch == 'main' || branch == 'master') return false;
  if (isProtectedBranch(branch)) return false;
  final branchLower = branch.toLowerCase();
  if (alreadyMatchedBranches.contains(branchLower)) return false;
  final compositeKey = '$repoKey#$branchLower';
  return !alreadyMatchedBranches.contains(compositeKey);
}

List<LandedPr> _fetchBatchCrossAuthorPrs(
  List<_CandidateBranch> candidates,
  SyncProcessRunner runner, {
  int? lastNDays,
  void Function(String message)? onProgress,
}) {
  final results = <LandedPr>[];
  final seenPrKeys = <String>{};
  const batchSize = 30;

  DateTime? cutoff;
  if (lastNDays != null) {
    cutoff = DateTime.now().toUtc().subtract(Duration(days: lastNDays));
  }

  for (var i = 0; i < candidates.length; i += batchSize) {
    final batch = candidates.skip(i).take(batchSize).toList();
    final queryStr = _buildBatchCrossAuthorQuery(batch);
    final result = runner('gh', ['api', 'graphql', '-f', 'query=$queryStr']);
    final data = _tryParseGraphQLData(result.stdout);
    if (data == null) {
      if (result.exitCode != 0) {
        stderr.writeln(
          'Warning: Failed to fetch cross-author PR data: '
          '${result.stderr.toString().trim()}',
        );
      }
      continue;
    }

    _extractLandedPrsFromBatch(data, batch, cutoff, seenPrKeys, results);
  }

  return results;
}

String _buildBatchCrossAuthorQuery(List<_CandidateBranch> batch) {
  final buffer = StringBuffer('query {\n');
  for (var b = 0; b < batch.length; b++) {
    final item = batch[b];
    final encOwner = jsonEncode(item.owner);
    final encName = jsonEncode(item.name);
    final encBranch = jsonEncode(item.branch);
    buffer.writeln(
      '  q$b: repository(owner: $encOwner, name: $encName) {\n'
      '    nameWithOwner\n'
      '    url\n'
      '    pullRequests(\n'
      '      headRefName: $encBranch,\n'
      '      states: [MERGED],\n'
      '      first: 1,\n'
      '      orderBy: {field: CREATED_AT, direction: DESC}\n'
      '    ) {\n'
      '      nodes {\n'
      '        number\n'
      '        title\n'
      '        url\n'
      '        mergedAt\n'
      '        closedAt\n'
      '        headRefName\n'
      '        headRefOid\n'
      '        headRef {\n'
      '          name\n'
      '        }\n'
      '        headRepository {\n'
      '          nameWithOwner\n'
      '          viewerPermission\n'
      '        }\n'
      '        baseRefName\n'
      '        mergeCommit {\n'
      '          oid\n'
      '        }\n'
      '      }\n'
      '    }\n'
      '  }',
    );
  }
  buffer.writeln('}');
  return buffer.toString();
}

void _extractLandedPrsFromBatch(
  Map<String, dynamic> data,
  List<_CandidateBranch> batch,
  DateTime? cutoff,
  Set<String> seenPrKeys,
  List<LandedPr> results,
) {
  for (var b = 0; b < batch.length; b++) {
    final landedPr = _parseBatchItemLandedPr(data, b, cutoff);
    if (landedPr == null) continue;

    final key = '${landedPr.repository}#${landedPr.number}'.toLowerCase();
    if (seenPrKeys.add(key)) {
      results.add(landedPr);
    }
  }
}

LandedPr? _parseBatchItemLandedPr(
  Map<String, dynamic> data,
  int index,
  DateTime? cutoff,
) {
  final qVal = data['q$index'];
  if (qVal is! Map<String, dynamic>) return null;
  final prsVal = qVal['pullRequests'];
  if (prsVal is! Map<String, dynamic>) return null;
  final prNodes = prsVal['nodes'] as List<dynamic>?;
  if (prNodes == null || prNodes.isEmpty) return null;

  final node = prNodes.first;
  if (node is! Map<String, dynamic>) return null;

  node['repository'] = {
    'nameWithOwner': qVal['nameWithOwner'],
    'url': qVal['url'],
  };

  final landedPr = parseLandedPrNode(node);
  if (landedPr == null) return null;

  if (cutoff != null &&
      landedPr.mergedAt != null &&
      landedPr.mergedAt!.isBefore(cutoff)) {
    return null;
  }

  return landedPr;
}

typedef _CandidateWorktree = ({
  LocalRepoInfo repo,
  LocalWorktreeEntry wt,
  String owner,
  String name,
});

/// Discovers worktrees across [localRepos] that have no matching PR on GitHub.
///
/// [matchedWorktreePaths] is the set of worktree paths that were matched to
/// landed PRs and are already being handled.
Future<List<UnlinkedWorktree>> findUnlinkedWorktrees(
  List<LocalRepoInfo> localRepos,
  Set<String> matchedWorktreePaths, {
  String? repoFilter,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final candidates = _collectCandidateWorktrees(
    localRepos,
    matchedWorktreePaths,
    repoFilter: repoFilter,
  );

  final unlinkedCandidates = [
    ...candidates.detachedCandidates,
    ..._filterUnlinkedCandidates(candidates.branchCandidates, runner),
  ];

  return [
    for (final item in unlinkedCandidates)
      _populateUnlinkedWorktreeDetails(item, runner),
  ]..sort((a, b) {
    final repoCmp = a.repository.toLowerCase().compareTo(
      b.repository.toLowerCase(),
    );
    if (repoCmp != 0) return repoCmp;
    return a.worktreePath.toLowerCase().compareTo(b.worktreePath.toLowerCase());
  });
}

({
  List<_CandidateWorktree> branchCandidates,
  List<({LocalRepoInfo repo, LocalWorktreeEntry wt})> detachedCandidates,
})
_collectCandidateWorktrees(
  List<LocalRepoInfo> localRepos,
  Set<String> matchedWorktreePaths, {
  String? repoFilter,
}) {
  final candidates = <_CandidateWorktree>[];
  final detachedCandidates = <({LocalRepoInfo repo, LocalWorktreeEntry wt})>[];

  for (final r in _filteredRootRepos(localRepos, repoFilter: repoFilter)) {
    _classifyRepoWorktrees(
      r.repo,
      r.owner,
      r.name,
      matchedWorktreePaths,
      candidates,
      detachedCandidates,
    );
  }

  return (branchCandidates: candidates, detachedCandidates: detachedCandidates);
}

void _classifyRepoWorktrees(
  LocalRepoInfo repo,
  String owner,
  String name,
  Set<String> matchedWorktreePaths,
  List<_CandidateWorktree> candidates,
  List<({LocalRepoInfo repo, LocalWorktreeEntry wt})> detachedCandidates,
) {
  for (final wt in repo.worktrees) {
    if (!_isCandidateWorktree(wt, repo.repoPath, matchedWorktreePaths)) {
      continue;
    }

    if (wt.branch.isEmpty || wt.branch == 'DETACHED') {
      detachedCandidates.add((repo: repo, wt: wt));
    } else {
      candidates.add((repo: repo, wt: wt, owner: owner, name: name));
    }
  }
}

bool _isCandidateWorktree(
  LocalWorktreeEntry wt,
  String repoPath,
  Set<String> matchedWorktreePaths,
) {
  if (wt.path == repoPath) return false;
  if (matchedWorktreePaths.contains(wt.path)) return false;
  return Directory(wt.path).existsSync();
}

List<({LocalRepoInfo repo, LocalWorktreeEntry wt})> _filterUnlinkedCandidates(
  List<_CandidateWorktree> candidates,
  SyncProcessRunner runner,
) {
  if (candidates.isEmpty) return const [];
  final unlinked = <({LocalRepoInfo repo, LocalWorktreeEntry wt})>[];
  const batchSize = 30;

  for (var i = 0; i < candidates.length; i += batchSize) {
    final batch = candidates.skip(i).take(batchSize).toList();
    final queryStr = _buildBatchWorktreePrQuery(batch);
    final result = runner('gh', ['api', 'graphql', '-f', 'query=$queryStr']);
    if (result.exitCode != 0) {
      stderr.writeln(
        'Warning: Failed to fetch GraphQL PR data for candidate worktrees: '
        '${result.stderr.toString().trim()}',
      );
      continue;
    }

    final data = _tryParseGraphQLData(result.stdout);
    if (data == null) {
      stderr.writeln(
        'Warning: Could not parse GraphQL response for candidate worktrees.',
      );
      continue;
    }

    for (var b = 0; b < batch.length; b++) {
      if (!_batchItemHasPr(data, b)) {
        unlinked.add((repo: batch[b].repo, wt: batch[b].wt));
      }
    }
  }

  return unlinked;
}

bool _batchItemHasPr(Map<String, dynamic>? data, int index) {
  final qVal = data?['q$index'];
  final qMap = qVal is Map<String, dynamic> ? qVal : null;
  final prsVal = qMap?['pullRequests'];
  final prsMap = prsVal is Map<String, dynamic> ? prsVal : null;
  final prNodes = (prsMap?['nodes'] as List<dynamic>?) ?? [];
  return prNodes.isNotEmpty;
}

String _buildBatchWorktreePrQuery(List<_CandidateWorktree> batch) {
  final queryBuffer = StringBuffer('query {\n');
  for (var b = 0; b < batch.length; b++) {
    final item = batch[b];
    final encOwner = jsonEncode(item.owner);
    final encName = jsonEncode(item.name);
    final encBranch = jsonEncode(item.wt.branch);
    queryBuffer.writeln(
      '  q$b: repository(owner: $encOwner, name: $encName) {\n'
      '    pullRequests(headRefName: $encBranch, first: 1) {\n'
      '      nodes {\n'
      '        number\n'
      '        state\n'
      '      }\n'
      '    }\n'
      '  }',
    );
  }
  queryBuffer.writeln('}');
  return queryBuffer.toString();
}

UnlinkedWorktree _populateUnlinkedWorktreeDetails(
  ({LocalRepoInfo repo, LocalWorktreeEntry wt}) item,
  SyncProcessRunner runner,
) {
  final repo = item.repo;
  final wt = item.wt;
  final trunk = resolveTrunkBranch(repo);
  final commitsAhead = _countCommitsAhead(wt.path, trunk, runner);
  final lastCommit = _getLastCommitInfo(wt.path, runner);
  final worktreeAge = _computeWorktreeAge(wt.path);
  final formattedDate = lastCommit.date != null && worktreeAge != null
      ? '${lastCommit.date} ($worktreeAge)'
      : lastCommit.date ?? worktreeAge;

  return (
    repository: repo.repoName,
    worktreePath: wt.path,
    branch: wt.branch.isEmpty ? '(detached)' : wt.branch,
    sha: wt.sha,
    commitsAhead: commitsAhead,
    lastCommitDate: formattedDate,
    lastCommitSubject: lastCommit.subject,
  );
}

String? _computeWorktreeAge(String worktreePath, {DateTime? now}) {
  try {
    final gitStat = FileStat.statSync('$worktreePath/.git');
    final modified = gitStat.type != FileSystemEntityType.notFound
        ? gitStat.modified
        : Directory(worktreePath).statSync().modified;
    final refNow = now ?? DateTime.now();
    final diff = refNow.difference(modified);
    if (diff.isNegative) return '🟢 just now';
    if (diff.inMinutes < 60) return '🟢 ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '🟢 ${diff.inHours}h ago';
    return null;
  } catch (_) {
    return null;
  }
}

int? _countCommitsAhead(
  String worktreePath,
  String trunkBranch,
  SyncProcessRunner runner, {
  String headRef = 'HEAD',
}) {
  final refs = ['origin/$trunkBranch', 'upstream/$trunkBranch', trunkBranch];
  for (final ref in refs) {
    final revResult = runner('git', [
      'rev-list',
      '--count',
      '$ref..$headRef',
    ], workingDirectory: worktreePath);
    if (revResult.exitCode == 0) {
      final parsed = int.tryParse((revResult.stdout as String).trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

({String? date, String? subject}) _getLastCommitInfo(
  String worktreePath,
  SyncProcessRunner runner,
) {
  final logResult = runner('git', [
    'log',
    '-1',
    '--format=%cs|%s',
  ], workingDirectory: worktreePath);
  if (logResult.exitCode != 0) return (date: null, subject: null);
  final out = (logResult.stdout as String).trim();
  if (out.isEmpty) return (date: null, subject: null);

  final parts = out.split('|');
  final date = parts[0].trim();
  final subject = parts.length > 1 ? parts.sublist(1).join('|').trim() : null;
  return (date: date, subject: subject);
}

/// Discovers local branches and worktrees across [localRepos] whose GitHub PR
/// was closed without merging (`state == 'CLOSED'` and no open PR exists for
/// that branch).
Future<List<ClosedUnmergedPr>> findClosedUnmergedPrs(
  List<LocalRepoInfo> localRepos,
  Set<String> alreadyMatchedBranches, {
  String? repoFilter,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final candidates = _collectCandidateBranches(
    localRepos,
    alreadyMatchedBranches,
    repoFilter: repoFilter,
  );
  if (candidates.isEmpty) return const [];

  final results = <ClosedUnmergedPr>[];
  final seenKeys = <String>{};
  const batchSize = 30;

  for (var i = 0; i < candidates.length; i += batchSize) {
    final batch = candidates.skip(i).take(batchSize).toList();
    _extractClosedUnmergedFromBatch(batch, seenKeys, results, runner);
  }

  return results..sort((a, b) {
    final repoCmp = a.repository.toLowerCase().compareTo(
      b.repository.toLowerCase(),
    );
    if (repoCmp != 0) return repoCmp;
    return a.number.compareTo(b.number);
  });
}

void _extractClosedUnmergedFromBatch(
  List<_CandidateBranch> batch,
  Set<String> seenKeys,
  List<ClosedUnmergedPr> results,
  SyncProcessRunner runner,
) {
  final queryStr = _buildBatchClosedUnmergedQuery(batch);
  final res = runner('gh', ['api', 'graphql', '-f', 'query=$queryStr']);
  if (res.exitCode != 0) return;

  final data = _tryParseGraphQLData(res.stdout);
  if (data == null) return;

  for (var b = 0; b < batch.length; b++) {
    final item = _parseClosedUnmergedBatchItem(data, b, batch[b], runner);
    if (item == null) continue;
    final key = '${item.repository}#${item.branch}'.toLowerCase();
    if (seenKeys.add(key)) {
      results.add(item);
    }
  }
}

String _buildBatchClosedUnmergedQuery(List<_CandidateBranch> batch) {
  final buffer = StringBuffer('query {\n');
  for (var b = 0; b < batch.length; b++) {
    final item = batch[b];
    final encOwner = jsonEncode(item.owner);
    final encName = jsonEncode(item.name);
    final encBranch = jsonEncode(item.branch);
    buffer.writeln(
      '  q$b: repository(owner: $encOwner, name: $encName) {\n'
      '    nameWithOwner\n'
      '    openPrs: pullRequests(\n'
      '      headRefName: $encBranch,\n'
      '      states: [OPEN],\n'
      '      first: 1\n'
      '    ) {\n'
      '      nodes { number }\n'
      '    }\n'
      '    mergedPrs: pullRequests(\n'
      '      headRefName: $encBranch,\n'
      '      states: [MERGED],\n'
      '      first: 1\n'
      '    ) {\n'
      '      nodes { number }\n'
      '    }\n'
      '    closedPrs: pullRequests(\n'
      '      headRefName: $encBranch,\n'
      '      states: [CLOSED],\n'
      '      first: 1,\n'
      '      orderBy: {field: CREATED_AT, direction: DESC}\n'
      '    ) {\n'
      '      nodes {\n'
      '        number\n'
      '        title\n'
      '        url\n'
      '        headRefOid\n'
      '      }\n'
      '    }\n'
      '  }',
    );
  }
  buffer.writeln('}');
  return buffer.toString();
}

ClosedUnmergedPr? _parseClosedUnmergedBatchItem(
  Map<String, dynamic> data,
  int index,
  _CandidateBranch candidate,
  SyncProcessRunner runner,
) {
  final qVal = data['q$index'];
  if (qVal is! Map<String, dynamic>) return null;

  final openNodes =
      ((qVal['openPrs'] as Map<String, dynamic>?)?['nodes'] as List?) ??
      const [];
  if (openNodes.isNotEmpty) return null;

  final mergedNodes =
      ((qVal['mergedPrs'] as Map<String, dynamic>?)?['nodes'] as List?) ??
      const [];
  if (mergedNodes.isNotEmpty) return null;

  final closedNodes =
      ((qVal['closedPrs'] as Map<String, dynamic>?)?['nodes'] as List?) ??
      const [];
  if (closedNodes.isEmpty) return null;

  final node = closedNodes.first;
  if (node is! Map<String, dynamic>) return null;

  final number = node['number'] as int?;
  final title = node['title'] as String?;
  final url = node['url'] as String?;
  final headRefOid = (node['headRefOid'] as String?) ?? '';
  if (number == null || title == null || url == null) return null;

  final repo = candidate.repo;
  final branch = candidate.branch;
  final repoShortName = repo.repoName.split('/').last;
  final matchingWt = findMatchingWorktree(repo, branch, repoShortName);
  final worktreePath =
      matchingWt != null && matchingWt.isCheckedOutOnBranch(branch)
      ? matchingWt.path
      : null;

  final localBranch = repo.branches.where((b) => b.name == branch).firstOrNull;
  final localSha = localBranch?.sha ?? matchingWt?.sha ?? '';
  final trunk = resolveTrunkBranch(repo);
  final commitsAhead = _countCommitsAhead(
    worktreePath ?? repo.repoPath,
    trunk,
    runner,
    headRef: branch,
  );

  return (
    repository: (qVal['nameWithOwner'] as String?) ?? repo.repoName,
    number: number,
    title: title,
    url: url,
    branch: branch,
    headRefOid: headRefOid,
    localSha: localSha,
    worktreePath: worktreePath,
    commitsAhead: commitsAhead,
    shaMatchesPrHead: headRefOid.isNotEmpty && localSha == headRefOid,
  );
}
