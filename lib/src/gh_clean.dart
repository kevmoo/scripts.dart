import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import 'local_repo_scanner.dart';
import 'process_utils.dart';
import 'shared/gh_args.dart';
import 'shared/gh_pr_ref.dart';
import 'shared/graphql_utils.dart';

export 'local_repo_scanner.dart'
    show findMatchingWorktree, findMatchingWorktreeForPr;
export 'shared/gh_pr_ref.dart' show GhPrRef;

/// Exception thrown by `gh-clean` operations.
class GhCleanException implements Exception {
  final String message;
  final int exitCode;

  new(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}

/// Representation of a merged GitHub Pull Request.
class LandedPr extends GhPrRef {
  final String? mergeSha;
  final DateTime? mergedAt;
  final DateTime? closedAt;
  final bool headRefExists;
  final String? headRepository;
  final String? headRepoPermission;

  const new({
    required super.number,
    required super.title,
    required super.url,
    required super.repository,
    required super.repoUrl,
    required super.headRefName,
    required super.headRefOid,
    required super.baseRefName,
    this.mergeSha,
    this.mergedAt,
    this.closedAt,
    this.headRefExists = false,
    this.headRepository,
    this.headRepoPermission,
  });

  /// Whether the remote head branch still exists on GitHub and can be
  /// deleted by the current viewer.
  bool get canDeleteRemoteHeadBranch =>
      headRefExists &&
      headRepository != null &&
      headRepository!.isNotEmpty &&
      headRefName.isNotEmpty &&
      headRefName != baseRefName &&
      !_isTrunkBranchName(headRefName) &&
      (headRepository!.toLowerCase() != repository.toLowerCase() ||
          !_isProtectedBranch(headRefName)) &&
      (headRepoPermission == 'ADMIN' || headRepoPermission == 'WRITE');
}

/// A single cleanup action executed on a repository.
typedef CleanAction = ({String description, bool success, String? error});

/// Full status and cleanup result for a landed PR.
typedef PrCleanResult = ({
  LandedPr pr,
  LocalRepoInfo? localRepo,
  List<String> plannedActions,
  List<CleanAction> executedActions,
  String status,
});

/// Information about a local secondary worktree that has no associated PR
/// on GitHub.
typedef UnlinkedWorktree = ({
  String repository,
  String worktreePath,
  String branch,
  String sha,
  int? commitsAhead,
  String? lastCommitDate,
  String? lastCommitSubject,
});

/// Options for configuring `gh-clean`.
class GhCleanOptions {
  final String user;
  final String? repo;
  final int limit;
  final int? lastNDays;
  final bool apply;
  final bool json;
  final bool markdown;
  final String? localRoot;
  final bool skipSync;
  final bool skipWorktrees;
  final bool skipRemoteBranches;
  final bool includeOwned;

  const new({
    this.user = '@me',
    this.repo,
    this.limit = 50,
    this.lastNDays = 7,
    this.apply = false,
    this.json = false,
    this.markdown = false,
    this.localRoot,
    this.skipSync = false,
    this.skipWorktrees = false,
    this.skipRemoteBranches = false,
    this.includeOwned = true,
  });

  static ArgParser createArgParser() {
    final parser = ArgParser();
    addCommonGhArgs(
      parser,
      itemType: 'PRs',
      lastNDaysAction: 'merged',
      limitHelpSuffix: ' (capped at 100)',
    );
    parser
      ..addFlag(
        'apply',
        negatable: false,
        help: 'Execute worktree pruning, branch deletion, and trunk sync.',
      )
      ..addOption(
        'local-root',
        help:
            'Base directory for local Git repositories (defaults to ~/github).',
      )
      ..addFlag(
        'skip-sync',
        negatable: false,
        help: 'Skip fast-forwarding default branches against origin.',
      )
      ..addFlag(
        'skip-worktrees',
        negatable: false,
        help: 'Skip pruning matching sibling worktrees.',
      )
      ..addFlag(
        'skip-remote-branches',
        negatable: false,
        help: 'Skip deleting merged head branches on GitHub remotes.',
      )
      ..addFlag(
        'include-owned',
        defaultsTo: true,
        help: 'Include repositories owned by the user.',
      );
    return parser;
  }
}

/// Main orchestration logic for `gh-clean`.
Future<void> runGhClean({
  required GhCleanOptions options,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;

  onProgress?.call('Fetching landed pull requests from GitHub...');
  final landedPrs = await fetchLandedPrs(
    user: options.user,
    repo: options.repo,
    lastNDays: options.lastNDays,
    limit: options.limit,
    includeOwned: options.includeOwned,
    processRunner: runner,
  );
  onProgress?.call('Found ${landedPrs.length} landed pull request(s).');

  final rootPath =
      options.localRoot ??
      Platform.environment['GH_LOCAL_ROOT'] ??
      '${Platform.environment['HOME']}/github';
  final rootDir = Directory(rootPath);

  onProgress?.call('Scanning local Git repositories in $rootPath...');
  final localRepos = scanLocalGitRepositories(rootDir, processRunner: runner);
  final repoMap = _buildRepoMap(localRepos);
  onProgress?.call(
    'Indexed ${localRepos.length} local repository checkout(s).',
  );

  final matchedHeadRefs = {
    for (final pr in landedPrs)
      '${pr.repository}#${pr.headRefName}'.toLowerCase(),
  };

  onProgress?.call(
    'Checking for landed PRs from collaborators or takeovers...',
  );
  final crossAuthorPrs = await findCrossAuthorLandedPrs(
    localRepos,
    matchedHeadRefs,
    lastNDays: options.lastNDays,
    repoFilter: options.repo,
    processRunner: runner,
    onProgress: onProgress,
  );
  if (crossAuthorPrs.isNotEmpty) {
    onProgress?.call(
      'Found ${crossAuthorPrs.length} collaborator/takeover landed PR(s).',
    );
  }

  final allLandedPrs = [...landedPrs, ...crossAuthorPrs]
    ..sort((a, b) {
      final repoCmp = a.repository.toLowerCase().compareTo(
        b.repository.toLowerCase(),
      );
      if (repoCmp != 0) return repoCmp;
      return a.number.compareTo(b.number);
    });

  final results = [
    for (final pr in allLandedPrs)
      _processPr(
        pr,
        repoMap[pr.repository.toLowerCase()],
        options: options,
        runner: runner,
        onProgress: onProgress,
      ),
  ];

  final matchedWorktreePaths = <String>{};
  for (final r in results) {
    if (r.localRepo == null) continue;
    final matchingWt = findMatchingWorktreeForPr(r.localRepo!, r.pr);
    if (matchingWt != null) {
      matchedWorktreePaths.add(matchingWt.path);
    }
  }

  onProgress?.call('Checking for worktrees with no associated PR...');
  final unlinkedWorktrees = options.skipWorktrees
      ? const <UnlinkedWorktree>[]
      : await findUnlinkedWorktrees(
          localRepos,
          matchedWorktreePaths,
          repoFilter: options.repo,
          processRunner: runner,
          onProgress: onProgress,
        );
  if (unlinkedWorktrees.isNotEmpty) {
    onProgress?.call(
      'Found ${unlinkedWorktrees.length} worktree(s) with no associated PR.',
    );
  }

  _outputReport(results, options, unlinkedWorktrees: unlinkedWorktrees);
}

Map<String, LocalRepoInfo> _buildRepoMap(List<LocalRepoInfo> localRepos) {
  final repoMap = <String, LocalRepoInfo>{};
  for (final repo in localRepos) {
    for (final name in repo.repoNames) {
      final key = name.toLowerCase();
      final isRoot = isRootGitRepository(Directory(repo.repoPath));
      final existing = repoMap[key];
      if (existing == null || isRoot) {
        repoMap[key] = repo;
      }
    }
  }
  return repoMap;
}

PrCleanResult _processPr(
  LandedPr pr,
  LocalRepoInfo? localRepo, {
  required GhCleanOptions options,
  required SyncProcessRunner runner,
  void Function(String message)? onProgress,
}) {
  final planned = planCleanup(
    pr,
    localRepo,
    skipSync: options.skipSync,
    skipWorktrees: options.skipWorktrees,
    skipRemoteBranches: options.skipRemoteBranches,
    processRunner: runner,
  );

  var executed = <CleanAction>[];
  var status = 'Pending';

  if (planned.isEmpty) {
    status = localRepo == null ? 'Not cloned locally' : 'Clean (nothing to do)';
  } else if (options.apply) {
    onProgress?.call(
      '[apply] Cleaning ${pr.repository} #${pr.number} (${pr.headRefName})...',
    );
    executed = executeCleanup(
      pr,
      localRepo,
      skipSync: options.skipSync,
      skipWorktrees: options.skipWorktrees,
      skipRemoteBranches: options.skipRemoteBranches,
      processRunner: runner,
      onProgress: onProgress,
    );
    final allSucceeded = executed.every((a) => a.success);
    status = allSucceeded ? 'Applied' : 'Partial Failure';
  }

  return (
    pr: pr,
    localRepo: localRepo,
    plannedActions: planned,
    executedActions: executed,
    status: status,
  );
}

void _outputReport(
  List<PrCleanResult> results,
  GhCleanOptions options, {
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) {
  if (options.json) {
    print(
      jsonEncode(
        formatJsonReport(
          results,
          applied: options.apply,
          unlinkedWorktrees: unlinkedWorktrees,
        ),
      ),
    );
  } else if (options.markdown) {
    print(
      formatMarkdownReport(
        results,
        applied: options.apply,
        unlinkedWorktrees: unlinkedWorktrees,
      ),
    );
  } else {
    printTerminalReport(
      results,
      applied: options.apply,
      unlinkedWorktrees: unlinkedWorktrees,
    );
  }
}

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
  final rootRepos = localRepos.where(
    (r) => isRootGitRepository(Directory(r.repoPath)),
  );

  for (final repo in rootRepos) {
    if (!_isRepoMatchingFilter(repo, repoFilter)) continue;
    final parsedRepo = _parseRepoOwnerAndName(repo);
    if (parsedRepo == null) continue;

    _collectRepoCandidateBranches(
      repo,
      parsedRepo.owner,
      parsedRepo.name,
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
  if (_isProtectedBranch(branch)) return false;
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

bool _isTrunkSynced(LocalRepoInfo localRepo, String trunkBranch) {
  final trunk = localRepo.branches
      .where((b) => b.name == trunkBranch)
      .firstOrNull;
  return trunk != null && trunk.isUpToDateWithUpstream;
}

/// Identifies candidate cleanup actions without performing mutations.
List<String> planCleanup(
  LandedPr pr,
  LocalRepoInfo? localRepo, {
  bool skipSync = false,
  bool skipWorktrees = false,
  bool skipRemoteBranches = false,
  SyncProcessRunner? processRunner,
}) {
  final actions = <String>[];

  if (!skipRemoteBranches && pr.canDeleteRemoteHeadBranch) {
    actions.add(
      'Delete remote branch `${pr.headRepository}:${pr.headRefName}`',
    );
  }

  if (localRepo == null) return actions;
  final runner = processRunner ?? defaultSyncProcessRunner;

  final headBranch = pr.headRefName;
  final trunkBranch = _resolveTrunkBranch(pr, localRepo);
  final repoShortName = pr.repository.split('/').last;

  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt != null && !skipWorktrees) {
    if (_isDirDirty(matchingWt.path, runner)) {
      actions.add(
        'Skip worktree at ${matchingWt.path} (has uncommitted changes)',
      );
    } else {
      actions.add('Prune worktree at ${matchingWt.path}');
    }
  }

  if (localRepo.currentBranch == headBranch && headBranch.isNotEmpty) {
    actions.add('Switch branch: `$headBranch` -> `$trunkBranch`');
  }

  if (headBranch.isNotEmpty &&
      headBranch != trunkBranch &&
      !_isProtectedBranch(headBranch) &&
      localRepo.branches.any((b) => b.name == headBranch)) {
    actions.add('Delete local branch `$headBranch`');
  }

  if (!skipSync && !_isTrunkSynced(localRepo, trunkBranch)) {
    actions.add('Sync `$trunkBranch` to `origin/$trunkBranch`');
  }

  return actions;
}

/// Executes worktree pruning, branch deletion, default branch sync, and remote
/// branch deletion.
List<CleanAction> executeCleanup(
  LandedPr pr,
  LocalRepoInfo? localRepo, {
  bool skipSync = false,
  bool skipWorktrees = false,
  bool skipRemoteBranches = false,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final actions = <CleanAction>[];

  if (localRepo != null) {
    _executeLocalRepoCleanup(
      pr,
      localRepo,
      skipSync: skipSync,
      skipWorktrees: skipWorktrees,
      runner: runner,
      actions: actions,
      onProgress: onProgress,
    );
  }

  if (!skipRemoteBranches && pr.canDeleteRemoteHeadBranch) {
    _recordAction(
      actions,
      _executeRemoteBranchDeletion(pr, localRepo, runner),
      onProgress,
    );
  }

  return actions;
}

void _recordAction(
  List<CleanAction> actions,
  CleanAction? action,
  void Function(String message)? onProgress,
) {
  if (action == null) return;
  actions.add(action);
  onProgress?.call('  ${action.success ? "✓" : "✗"} ${action.description}');
}

void _executeLocalRepoCleanup(
  LandedPr pr,
  LocalRepoInfo localRepo, {
  required bool skipSync,
  required bool skipWorktrees,
  required SyncProcessRunner runner,
  required List<CleanAction> actions,
  void Function(String message)? onProgress,
}) {
  final headBranch = pr.headRefName;
  final trunkBranch = _resolveTrunkBranch(pr, localRepo);
  final repoShortName = pr.repository.split('/').last;

  if (!skipWorktrees) {
    _recordAction(
      actions,
      _executeWorktreePrune(localRepo, headBranch, repoShortName, runner),
      onProgress,
    );
  }

  _recordAction(
    actions,
    _executeBranchCheckout(localRepo, headBranch, trunkBranch, runner),
    onProgress,
  );

  if (!skipSync) {
    _recordAction(
      actions,
      _executeTrunkSync(localRepo, headBranch, trunkBranch, runner),
      onProgress,
    );
  }

  _recordAction(
    actions,
    _executeBranchDeletion(
      localRepo,
      headBranch,
      trunkBranch,
      pr.headRefOid,
      runner,
      prNumber: pr.number,
    ),
    onProgress,
  );
}

CleanAction? _executeRemoteBranchDeletion(
  LandedPr pr,
  LocalRepoInfo? localRepo,
  SyncProcessRunner runner,
) {
  if (!pr.canDeleteRemoteHeadBranch) return null;
  final headRepo = pr.headRepository!;
  final headBranch = pr.headRefName;
  final res = runner('gh', [
    'api',
    '-X',
    'DELETE',
    'repos/$headRepo/git/refs/heads/$headBranch',
  ]);
  if (res.exitCode != 0) {
    return (
      description: 'Delete remote branch `$headRepo:$headBranch`',
      success: false,
      error: res.stderr.toString().trim(),
    );
  }
  if (localRepo != null) {
    for (final remote in {'origin', headRepo.split('/').first}) {
      runner('git', [
        'branch',
        '-dr',
        '$remote/$headBranch',
      ], workingDirectory: localRepo.repoPath);
    }
  }
  return (
    description: 'Deleted remote branch `$headRepo:$headBranch`',
    success: true,
    error: null,
  );
}

/// Resolves the default/trunk branch name for [localRepo].
String resolveTrunkBranch(LocalRepoInfo localRepo, {String? preferredTrunk}) {
  if (preferredTrunk != null && _isProtectedBranch(preferredTrunk)) {
    return preferredTrunk;
  }
  for (final candidate in _trunkCandidates) {
    if (localRepo.branches.any((b) => b.name == candidate)) {
      return candidate;
    }
  }
  return 'main';
}

String _resolveTrunkBranch(LandedPr pr, LocalRepoInfo? localRepo) {
  if (localRepo == null) {
    return _isProtectedBranch(pr.baseRefName) ? pr.baseRefName : 'main';
  }
  return resolveTrunkBranch(localRepo, preferredTrunk: pr.baseRefName);
}

const _trunkCandidates = ['main', 'master', 'trunk', 'dev'];

CleanAction? _executeWorktreePrune(
  LocalRepoInfo localRepo,
  String headBranch,
  String repoShortName,
  SyncProcessRunner runner,
) {
  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt == null) return null;

  if (_isDirDirty(matchingWt.path, runner)) {
    return (
      description: 'Pruning worktree at ${matchingWt.path}',
      success: false,
      error: 'Worktree has uncommitted changes (dirty).',
    );
  }

  final res = runner('git', [
    '-C',
    localRepo.repoPath,
    'worktree',
    'remove',
    matchingWt.path,
  ]);

  return res.exitCode == 0
      ? (
          description: 'Pruned sibling worktree at ${matchingWt.path}',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to prune worktree at ${matchingWt.path}',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

CleanAction? _executeBranchCheckout(
  LocalRepoInfo localRepo,
  String headBranch,
  String baseBranch,
  SyncProcessRunner runner,
) {
  if (localRepo.currentBranch != headBranch || headBranch.isEmpty) return null;

  final res = runner('git', ['-C', localRepo.repoPath, 'checkout', baseBranch]);
  return res.exitCode == 0
      ? (
          description: 'Switched from `$headBranch` to `$baseBranch`',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to checkout `$baseBranch`',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

CleanAction? _executeBranchDeletion(
  LocalRepoInfo localRepo,
  String headBranch,
  String trunkBranch,
  String? headRefOid,
  SyncProcessRunner runner, {
  int? prNumber,
}) {
  if (headBranch.isEmpty ||
      headBranch == trunkBranch ||
      _isProtectedBranch(headBranch) ||
      !localRepo.branches.any((b) => b.name == headBranch)) {
    return null;
  }

  // Check if all commits on the branch are already contained in trunk.
  // For squash-merged PRs where the local branch was advanced onto the squash
  // commit, headRefOid..headBranch is non-empty even though all work has landed
  // on trunk. Checking trunk containment first prevents false positives.
  var isContainedInTrunk = false;
  for (final ref in ['origin/$trunkBranch', trunkBranch]) {
    final countRes = runner('git', [
      '-C',
      localRepo.repoPath,
      'rev-list',
      '--count',
      '$ref..$headBranch',
    ]);
    if (countRes.exitCode == 0 && (countRes.stdout as String).trim() == '0') {
      isContainedInTrunk = true;
      break;
    }
  }

  if (!isContainedInTrunk) {
    if (headRefOid == null || headRefOid.isEmpty) {
      return (
        description: 'Delete local branch `$headBranch`',
        success: false,
        error:
            'Branch has unmerged commits, and PR HEAD could not be verified '
            '(empty headRefOid).',
      );
    }
    _ensureCommitExistsLocally(
      localRepo.repoPath,
      headRefOid,
      prNumber,
      runner,
    );
    final logRes = runner('git', [
      '-C',
      localRepo.repoPath,
      'log',
      '$headRefOid..$headBranch',
      '--oneline',
    ]);
    if (logRes.exitCode != 0) {
      return (
        description: 'Delete local branch `$headBranch`',
        success: false,
        error:
            'PR HEAD ($headRefOid) is not present locally and could not be '
            'verified.',
      );
    }
    if ((logRes.stdout as String).trim().isNotEmpty) {
      return (
        description: 'Delete local branch `$headBranch`',
        success: false,
        error: 'Branch has unpushed commits past PR HEAD ($headRefOid).',
      );
    }
  }

  final res = runner('git', [
    '-C',
    localRepo.repoPath,
    'branch',
    '-D',
    headBranch,
  ]);
  return res.exitCode == 0
      ? (
          description: 'Deleted local feature branch `$headBranch`',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to delete local branch `$headBranch`',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

void _ensureCommitExistsLocally(
  String repoPath,
  String commitSha,
  int? prNumber,
  SyncProcessRunner runner,
) {
  if (prNumber == null) return;
  final catRes = runner('git', ['-C', repoPath, 'cat-file', '-e', commitSha]);
  if (catRes.exitCode != 0) {
    runner('git', ['-C', repoPath, 'fetch', 'origin', 'pull/$prNumber/head']);
  }
}

CleanAction _executeTrunkSync(
  LocalRepoInfo localRepo,
  String headBranch,
  String trunkBranch,
  SyncProcessRunner runner,
) {
  final repoPath = localRepo.repoPath;
  final currentResult = runner('git', [
    'branch',
    '--show-current',
  ], workingDirectory: repoPath);
  final currentBranch = currentResult.exitCode == 0
      ? (currentResult.stdout as String).trim()
      : localRepo.currentBranch;
  final isOnTrunk = currentBranch == trunkBranch;

  if (isOnTrunk) {
    runner('git', ['-C', repoPath, 'fetch', 'origin']);
    final res = runner('git', [
      '-C',
      repoPath,
      'merge',
      '--ff-only',
      'origin/$trunkBranch',
    ]);
    return res.exitCode == 0
        ? (
            description: 'Synced `$trunkBranch` to `origin/$trunkBranch`',
            success: true,
            error: null,
          )
        : (
            description: 'Failed to fast-forward `$trunkBranch`',
            success: false,
            error: (res.stderr as String).trim(),
          );
  }

  final res = runner('git', [
    '-C',
    repoPath,
    'fetch',
    'origin',
    '$trunkBranch:$trunkBranch',
  ]);
  return res.exitCode == 0
      ? (
          description: 'Synced `$trunkBranch` to `origin/$trunkBranch`',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to fetch `$trunkBranch`',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

bool _isDirDirty(String path, SyncProcessRunner runner) => isRepoDirtySync(
  path,
  processRunner: runner,
  includeUntracked: true,
  failClosedOnProcessError: true,
);

bool _isTrunkBranchName(String branch) {
  final lower = branch.toLowerCase().trim();
  const trunkNames = {'main', 'master', 'trunk', 'dev', 'release', 'head'};
  return trunkNames.contains(lower);
}

bool _isProtectedBranch(String branch) {
  final lower = branch.toLowerCase().trim();
  if (lower.startsWith('release/') || lower.startsWith('release-')) {
    return true;
  }
  return _isTrunkBranchName(lower);
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

  final rootRepos = localRepos.where(
    (r) => isRootGitRepository(Directory(r.repoPath)),
  );
  for (final repo in rootRepos) {
    if (!_isRepoMatchingFilter(repo, repoFilter)) continue;

    final parsedRepo = _parseRepoOwnerAndName(repo);
    if (parsedRepo == null) continue;

    _classifyRepoWorktrees(
      repo,
      parsedRepo.owner,
      parsedRepo.name,
      matchedWorktreePaths,
      candidates,
      detachedCandidates,
    );
  }

  return (branchCandidates: candidates, detachedCandidates: detachedCandidates);
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

Map<String, dynamic>? _tryParseGraphQLData(Object? stdout) {
  if (stdout is! String || stdout.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(stdout) as Map<String, dynamic>?;
    return decoded?['data'] as Map<String, dynamic>?;
  } catch (_) {
    return null;
  }
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

  return (
    repository: repo.repoName,
    worktreePath: wt.path,
    branch: wt.branch.isEmpty ? '(detached)' : wt.branch,
    sha: wt.sha,
    commitsAhead: commitsAhead,
    lastCommitDate: lastCommit.date,
    lastCommitSubject: lastCommit.subject,
  );
}

int? _countCommitsAhead(
  String worktreePath,
  String trunkBranch,
  SyncProcessRunner runner,
) {
  final refs = ['origin/$trunkBranch', 'upstream/$trunkBranch', trunkBranch];
  for (final ref in refs) {
    final revResult = runner('git', [
      'rev-list',
      '--count',
      '$ref..HEAD',
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

/// Formats output as GitHub Flavored Markdown.
///
/// Rows are sorted by `org` -> `repo` -> `oldest PR number`.
/// Actionable PRs (requiring worktree pruning or branch deletion) are rendered
/// as individual rows with their specific PR link and actions. PRs with no
/// local branch/worktree mutations are clustered into a single summary row
/// per repository.
String formatMarkdownReport(
  List<PrCleanResult> results, {
  required bool applied,
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) {
  final buffer = StringBuffer()
    ..writeln('# Landed Pull Requests Cleanup Report')
    ..writeln()
    ..writeln(
      applied
          ? '**Mode**: 🚀 Applied Cleanup'
          : '**Mode**: 🔍 Preview Mode (Dry Run)',
    )
    ..writeln();

  if (results.isEmpty) {
    buffer.writeln('No recently landed pull requests found.');
  } else {
    buffer
      ..writeln('<!-- mdformat off -->')
      ..writeln('| Repository | PR(s) | Local Directory | Actions / Status |')
      ..writeln('| :--- | :--- | :--- | :--- |');

    final rows = _buildSortedReportRows(results, applied: applied);
    for (final row in rows) {
      buffer.writeln(row.markdown);
    }

    buffer.writeln('<!-- mdformat on -->');
  }

  if (unlinkedWorktrees.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Worktrees with No Associated PR')
      ..writeln()
      ..writeln('<!-- mdformat off -->')
      ..writeln(
        '| Repository | Worktree | Branch | Commits Ahead | Last Commit |',
      )
      ..writeln('| :--- | :--- | :--- | :---: | :--- |');

    for (final u in unlinkedWorktrees) {
      final repoLink =
          '[**${u.repository}**](https://github.com/${u.repository})';
      final wtLink =
          '[`${p.basename(u.worktreePath)}`](file://${u.worktreePath})';
      final branchStr = '`${u.branch}`';
      final aheadStr = u.commitsAhead != null ? '${u.commitsAhead}' : '?';
      final dateStr = u.lastCommitDate ?? '?';
      buffer.writeln(
        '| $repoLink | $wtLink | $branchStr | $aheadStr | $dateStr |',
      );
    }

    buffer.writeln('<!-- mdformat on -->');
  }

  return buffer.toString();
}

List<_ReportRow> _buildSortedReportRows(
  List<PrCleanResult> results, {
  required bool applied,
}) {
  final repoMap = <String, List<PrCleanResult>>{};
  for (final r in results) {
    repoMap.putIfAbsent(r.pr.repository, () => []).add(r);
  }

  final rows = <_ReportRow>[];

  for (final entry in repoMap.entries) {
    final list = entry.value;
    final parts = entry.key.split('/');
    final org = parts.isNotEmpty ? parts[0] : '';
    final repo = parts.length > 1 ? parts[1] : '';

    final actionable = list.where(_hasLocalBranchOrWorktreeAction).toList()
      ..sort((a, b) => a.pr.number.compareTo(b.pr.number));
    final noOps =
        list.where((r) => !_hasLocalBranchOrWorktreeAction(r)).toList()
          ..sort((a, b) => a.pr.number.compareTo(b.pr.number));

    for (final r in actionable) {
      rows.add((
        org: org,
        repo: repo,
        minPrNumber: r.pr.number,
        markdown: _formatActionableMarkdownRow(r, applied: applied),
      ));
    }

    if (noOps.isNotEmpty) {
      rows.add((
        org: org,
        repo: repo,
        minPrNumber: noOps.first.pr.number,
        markdown: _formatNoOpClusterMarkdownRow(noOps, applied: applied),
      ));
    }
  }

  rows.sort((a, b) {
    final orgCmp = a.org.toLowerCase().compareTo(b.org.toLowerCase());
    if (orgCmp != 0) return orgCmp;
    final repoCmp = a.repo.toLowerCase().compareTo(b.repo.toLowerCase());
    if (repoCmp != 0) return repoCmp;
    return a.minPrNumber.compareTo(b.minPrNumber);
  });

  return rows;
}

typedef _ReportRow = ({
  String org,
  String repo,
  int minPrNumber,
  String markdown,
});

bool _hasLocalBranchOrWorktreeAction(PrCleanResult r) =>
    r.plannedActions.any(
      (a) =>
          a.startsWith('Prune worktree') ||
          a.startsWith('Delete local branch') ||
          a.startsWith('Delete remote branch'),
    ) ||
    r.executedActions.any(
      (a) =>
          a.description.contains('worktree') ||
          a.description.contains('branch'),
    );

String _formatActionableMarkdownRow(PrCleanResult r, {required bool applied}) {
  final pr = r.pr;
  final repoLink = '[**${pr.repository}**](${pr.repoUrl})';
  final prLink = '[#${pr.number}](${pr.url})';
  final localDir = r.localRepo != null
      ? '[`${r.localRepo!.repoPath}`](file://${r.localRepo!.repoPath})'
      : '_Not cloned_';

  String statusDetail;
  if (applied) {
    statusDetail = r.executedActions
        .map((a) => '${a.success ? "✅" : "❌"} ${a.description}')
        .join('<br>');
  } else {
    statusDetail = r.plannedActions.map((a) => '• $a').join('<br>');
  }

  return '| $repoLink | $prLink | $localDir | $statusDetail |';
}

String _formatNoOpClusterMarkdownRow(
  List<PrCleanResult> list, {
  required bool applied,
}) {
  final first = list.first;
  final repoLink = '[**${first.pr.repository}**](${first.pr.repoUrl})';
  final prLinks = list.map((r) => '[#${r.pr.number}](${r.pr.url})').join(', ');
  final prLabel = list.length == 1
      ? '[#${first.pr.number}](${first.pr.url})'
      : '${list.length} PRs: $prLinks';

  final localDir = first.localRepo != null
      ? '[`${first.localRepo!.repoPath}`](file://${first.localRepo!.repoPath})'
      : '_Not cloned_';

  String statusDetail;
  if (first.localRepo == null) {
    statusDetail = '_Not cloned locally_';
  } else if (applied) {
    statusDetail = '✅ Up to date (no local branches)';
  } else {
    final hasPendingSync = list.any(
      (r) => r.plannedActions.any((a) => a.startsWith('Sync ')),
    );
    if (hasPendingSync) {
      statusDetail = '• Sync `main` to `origin/main` (no local branches)';
    } else {
      statusDetail = '✅ Up to date (no local branches)';
    }
  }

  return '| $repoLink | $prLabel | $localDir | $statusDetail |';
}

/// Formats output for terminal viewing.
void printTerminalReport(
  List<PrCleanResult> results, {
  required bool applied,
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) {
  final modeStr = applied
      ? green.wrap('🚀 Applied Cleanup')!
      : cyan.wrap('🔍 Preview Mode (Dry Run)')!;
  print('${styleBold.wrap("Landed PR Cleanup")} [$modeStr]\n');

  _printPrCleanResults(
    results,
    applied: applied,
    hasTrailingSection: unlinkedWorktrees.isNotEmpty,
  );
  _printUnlinkedWorktrees(unlinkedWorktrees);
}

void _printPrCleanResults(
  List<PrCleanResult> results, {
  required bool applied,
  required bool hasTrailingSection,
}) {
  if (results.isEmpty) {
    print(styleDim.wrap('No recently landed pull requests found.')!);
    if (hasTrailingSection) {
      print('');
    }
    return;
  }

  for (final r in results) {
    _printTerminalPrHeader(r);
    if (applied) {
      _printExecutedActions(r.executedActions);
    } else {
      _printPlannedActions(r.plannedActions, r.status);
    }
    print('');
  }
}

void _printUnlinkedWorktrees(List<UnlinkedWorktree> unlinkedWorktrees) {
  if (unlinkedWorktrees.isEmpty) return;

  print('${styleBold.wrap("Worktrees with No Associated PR:")}\n');
  for (final u in unlinkedWorktrees) {
    final folder = p.basename(u.worktreePath);
    final ahead = u.commitsAhead != null ? '${u.commitsAhead}' : 'unknown';
    final date = u.lastCommitDate ?? 'unknown';
    final subject =
        u.lastCommitSubject != null && u.lastCommitSubject!.isNotEmpty
        ? ' - "${u.lastCommitSubject}"'
        : '';
    print('  ${styleBold.wrap(folder)} (${u.repository})');
    print('    Branch:        ${u.branch}');
    print('    Path:          ${u.worktreePath}');
    print('    Commits Ahead: $ahead');
    print('    Last Commit:   $date$subject');
    print('');
  }
}

void _printTerminalPrHeader(PrCleanResult r) {
  final pr = r.pr;
  print('${styleBold.wrap("${pr.repository} #${pr.number}")}: ${pr.title}');
  print('  URL:    ${pr.url}');
  print('  Branch: ${pr.headRefName} -> ${pr.baseRefName}');
  if (r.localRepo != null) {
    print('  Local:  ${r.localRepo!.repoPath}');
  }
}

void _printExecutedActions(List<CleanAction> actions) {
  for (final act in actions) {
    final icon = act.success ? green.wrap('✅') : red.wrap('❌');
    print('  $icon ${act.description}');
    if (act.error != null) {
      print('     ${red.wrap("Error: ${act.error}")}');
    }
  }
}

void _printPlannedActions(List<String> plannedActions, String status) {
  if (plannedActions.isEmpty) {
    final statusColor = status == 'Not cloned locally'
        ? styleDim
        : status.contains('Failure')
        ? red
        : yellow;
    print('  Status: ${statusColor.wrap(status)}');
    return;
  }

  print('  Planned Actions:');
  for (final plan in plannedActions) {
    print('    • $plan');
  }
}

/// Formats output as machine-readable JSON.
Map<String, dynamic> formatJsonReport(
  List<PrCleanResult> results, {
  required bool applied,
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) => {
  'applied': applied,
  'total': results.length,
  'results': results
      .map(
        (r) => {
          'pr': {
            'number': r.pr.number,
            'title': r.pr.title,
            'url': r.pr.url,
            'repository': r.pr.repository,
            'headRefName': r.pr.headRefName,
            'baseRefName': r.pr.baseRefName,
            'mergedAt': r.pr.mergedAt?.toIso8601String(),
            'headRefExists': r.pr.headRefExists,
            'headRepository': r.pr.headRepository,
          },
          'localRepo': r.localRepo != null
              ? {
                  'repoName': r.localRepo!.repoName,
                  'repoPath': r.localRepo!.repoPath,
                  'currentBranch': r.localRepo!.currentBranch,
                }
              : null,
          'status': r.status,
          'plannedActions': r.plannedActions,
          'executedActions': r.executedActions
              .map(
                (a) => {
                  'description': a.description,
                  'success': a.success,
                  'error': a.error,
                },
              )
              .toList(),
        },
      )
      .toList(),
  'unlinkedWorktrees': [
    for (final u in unlinkedWorktrees)
      {
        'repository': u.repository,
        'worktreePath': u.worktreePath,
        'branch': u.branch,
        'sha': u.sha,
        'commitsAhead': u.commitsAhead,
        'lastCommitDate': u.lastCommitDate,
        'lastCommitSubject': u.lastCommitSubject,
      },
  ],
};
