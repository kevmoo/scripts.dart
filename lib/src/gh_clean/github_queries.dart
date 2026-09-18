import 'dart:convert';
import 'dart:io';

import '../local_repo_scanner.dart';
import '../process_utils.dart';
import '../shared/gh_pr_ref.dart';
import '../shared/graphql_utils.dart';
import 'models.dart';

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
  for (final r in filteredRootRepos(localRepos, repoFilter: repoFilter)) {
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
    final data = tryParseGraphQLData(result.stdout);
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
