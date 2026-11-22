import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../gh_clean/branch_policy.dart';
import '../gh_clean/cleanup_actions.dart';
import '../gh_clean/models.dart';
import '../local_repo_scanner.dart';
import '../process_utils.dart';
import '../shared/gh_args.dart';
import '../shared/graphql_utils.dart';
import 'models.dart';

/// Fork remote branches classified across `readyToPrune` and `needsTriage`.
typedef ForkBranchScanResult = ({
  List<PrunableItem> readyToPrune,
  List<TriageItem> additionalTriage,
  Map<String, String> remoteBranchByKey,
  Set<int> candidateLandedIds,
});

typedef _ForkRepoPair = ({
  LocalRepoInfo localRepo,
  String upstreamRepo,
  String forkOwner,
  String forkName,
});

typedef _RemoteForkRef = ({
  String name,
  String oid,
  DateTime? committedAt,
  String? authorLogin,
  String? committerLogin,
});

typedef _ForkBranchCandidate = ({
  LocalRepoInfo localRepo,
  String upstreamRepo,
  String forkRepo,
  String permission,
  String branch,
  String oid,
  DateTime? committedAt,
  Set<String> doNotDeleteOids,
});

/// Scans remote branches on user forks paired with locally cloned upstream
/// repositories so stale merged, closed-unmerged, duplicate archive, and
/// unlinked fork branches are surfaced and cleaned up.
ForkBranchScanResult scanForkRemoteBranches({
  required List<LocalRepoInfo> localRepos,
  required String user,
  required String? repoFilter,
  required Set<String> handledBranchKeys,
  required Set<String> existingTriageBranchKeys,
  required SyncProcessRunner syncRunner,
  void Function(String message)? onProgress,
}) {
  final multiOwnerRepos = _filterMultiOwnerRootRepos(localRepos, repoFilter);
  if (multiOwnerRepos.isEmpty) {
    return (
      readyToPrune: const [],
      additionalTriage: const [],
      remoteBranchByKey: const {},
      candidateLandedIds: const {},
    );
  }

  final forkRefs = _fetchForkRepoRefs(
    multiOwnerRepos: multiOwnerRepos,
    user: user,
    runner: syncRunner,
    onProgress: onProgress,
  );
  if (forkRefs.candidates.isEmpty) {
    return (
      readyToPrune: const [],
      additionalTriage: const [],
      remoteBranchByKey: const {},
      candidateLandedIds: const {},
    );
  }

  return _classifyForkBranchCandidates(
    candidates: forkRefs.candidates,
    resolvedUser: forkRefs.resolvedUser,
    handledBranchKeys: handledBranchKeys,
    existingTriageBranchKeys: existingTriageBranchKeys,
    runner: syncRunner,
  );
}

List<LocalRepoInfo> _filterMultiOwnerRootRepos(
  List<LocalRepoInfo> localRepos,
  String? repoFilter,
) {
  final filtersLower = {
    for (final r in splitRepoFilter(repoFilter)) r.toLowerCase(),
  };
  final matched = <LocalRepoInfo>[];
  for (final repo in localRepos) {
    if (!_isEligibleMultiOwnerRepo(repo, filtersLower)) continue;
    matched.add(repo);
  }
  return matched;
}

bool _isEligibleMultiOwnerRepo(LocalRepoInfo repo, Set<String> filtersLower) {
  if (!isRootGitRepository(Directory(repo.repoPath)) ||
      isDartSdkRepositoryName(repo.repoName)) {
    return false;
  }
  if (filtersLower.isNotEmpty &&
      !repo.repoNames.any((n) => filtersLower.contains(n.toLowerCase()))) {
    return false;
  }
  final owners = {
    for (final n in repo.repoNames)
      if (n.contains('/')) n.split('/').first.toLowerCase(),
  };
  return owners.length >= 2;
}

({String resolvedUser, List<_ForkBranchCandidate> candidates})
_fetchForkRepoRefs({
  required List<LocalRepoInfo> multiOwnerRepos,
  required String user,
  required SyncProcessRunner runner,
  void Function(String message)? onProgress,
}) {
  final initialPairs = _selectInitialForkPairs(multiOwnerRepos, user);
  if (initialPairs.isEmpty) {
    return (resolvedUser: user, candidates: const []);
  }

  onProgress?.call(
    'Scanning remote branches on ${initialPairs.length} fork '
    'repository/repositories...',
  );

  var resolvedUser = user;
  final candidates = <_ForkBranchCandidate>[];
  final queriedForks = <String>{};

  void runPass(List<_ForkRepoPair> pairs) {
    const batchSize = 15;
    for (var i = 0; i < pairs.length; i += batchSize) {
      final batch = pairs.skip(i).take(batchSize).toList();
      for (final p in batch) {
        queriedForks.add('${p.forkOwner}/${p.forkName}'.toLowerCase());
      }
      final viewer = _fetchForkBatch(
        batch: batch,
        currentResolvedUser: resolvedUser,
        runner: runner,
        candidatesOut: candidates,
      );
      if (resolvedUser == '@me' && viewer != null && viewer.isNotEmpty) {
        resolvedUser = viewer;
      }
    }
  }

  runPass(initialPairs);

  if (user == '@me' && resolvedUser != '@me') {
    final missed = _selectForkPairsForKnownUser(multiOwnerRepos, resolvedUser)
        .where(
          (p) => !queriedForks.contains(
            '${p.forkOwner}/${p.forkName}'.toLowerCase(),
          ),
        )
        .toList();
    if (missed.isNotEmpty) runPass(missed);
  }

  return (resolvedUser: resolvedUser, candidates: candidates);
}

List<_ForkRepoPair> _selectInitialForkPairs(
  List<LocalRepoInfo> repos,
  String user,
) {
  if (user != '@me') return _selectForkPairsForKnownUser(repos, user);
  final pairs = <_ForkRepoPair>[];
  for (final repo in repos) {
    final upstream = repo.repoNames.first;
    final upstreamOwner = upstream.split('/').first.toLowerCase();
    for (final entry in repo.repoNames.skip(1)) {
      final parts = entry.split('/');
      if (parts.length == 2 && parts[0].toLowerCase() != upstreamOwner) {
        pairs.add((
          localRepo: repo,
          upstreamRepo: upstream,
          forkOwner: parts[0],
          forkName: parts[1],
        ));
      }
    }
  }
  return pairs;
}

List<_ForkRepoPair> _selectForkPairsForKnownUser(
  List<LocalRepoInfo> repos,
  String knownUser,
) {
  final userLower = knownUser.toLowerCase();
  final pairs = <_ForkRepoPair>[];
  for (final repo in repos) {
    final upstream = repo.repoNames.firstWhereOrNull(
      (n) => n.contains('/') && n.split('/').first.toLowerCase() != userLower,
    );
    final fork = repo.repoNames.firstWhereOrNull(
      (n) => n.contains('/') && n.split('/').first.toLowerCase() == userLower,
    );
    if (upstream == null || fork == null) continue;
    final forkParts = fork.split('/');
    pairs.add((
      localRepo: repo,
      upstreamRepo: upstream,
      forkOwner: forkParts[0],
      forkName: forkParts[1],
    ));
  }
  return pairs;
}

String? _fetchForkBatch({
  required List<_ForkRepoPair> batch,
  required String currentResolvedUser,
  required SyncProcessRunner runner,
  required List<_ForkBranchCandidate> candidatesOut,
}) {
  final query = _buildForkRefsBatchQuery(batch);
  final res = runGhWithRetrySync(runner, [
    'api',
    'graphql',
    '-f',
    'query=$query',
  ]);
  final data = _tryDecodeGraphQLData(res.stdout);
  if (data == null) return null;

  final viewerLogin =
      (data['viewer'] as Map<String, dynamic>?)?['login'] as String?;
  final effectiveUser = currentResolvedUser == '@me'
      ? (viewerLogin ?? '')
      : currentResolvedUser;
  if (effectiveUser.isEmpty) return viewerLogin;

  for (var i = 0; i < batch.length; i++) {
    final repoNode = data['r$i'];
    if (repoNode is! Map<String, dynamic>) continue;
    _extractForkRepoCandidates(
      pair: batch[i],
      repoNode: repoNode,
      resolvedUser: effectiveUser,
      runner: runner,
      candidatesOut: candidatesOut,
    );
  }
  return viewerLogin;
}

String _buildForkRefsBatchQuery(List<_ForkRepoPair> batch) {
  final buf = StringBuffer('query {\n  viewer { login }\n');
  for (var i = 0; i < batch.length; i++) {
    final p = batch[i];
    buf.writeln(
      '  r$i: repository(owner: ${jsonEncode(p.forkOwner)}, '
      'name: ${jsonEncode(p.forkName)}) {\n'
      '    nameWithOwner\n'
      '    isFork\n'
      '    viewerPermission\n'
      '    defaultBranchRef { name }\n'
      '    parent { nameWithOwner }\n'
      '    refs(refPrefix: "refs/heads/", first: 100) {\n'
      '      pageInfo { hasNextPage endCursor }\n'
      '      nodes {\n'
      '        name\n'
      '        target {\n'
      '          ... on Commit {\n'
      '            oid\n'
      '            committedDate\n'
      '            author { user { login } }\n'
      '            committer { user { login } }\n'
      '          }\n'
      '        }\n'
      '      }\n'
      '    }\n'
      '  }',
    );
  }
  buf.writeln('}');
  return buf.toString();
}

void _extractForkRepoCandidates({
  required _ForkRepoPair pair,
  required Map<String, dynamic> repoNode,
  required String resolvedUser,
  required SyncProcessRunner runner,
  required List<_ForkBranchCandidate> candidatesOut,
}) {
  final forkRepo =
      (repoNode['nameWithOwner'] as String?) ??
      '${pair.forkOwner}/${pair.forkName}';
  if (!forkRepo.toLowerCase().startsWith('${resolvedUser.toLowerCase()}/')) {
    return;
  }
  if (repoNode['isFork'] != true) return;

  final parentName =
      (repoNode['parent'] as Map<String, dynamic>?)?['nameWithOwner']
          as String?;
  final upstreamRepo = parentName ?? pair.upstreamRepo;
  final defaultBranch =
      (repoNode['defaultBranchRef'] as Map<String, dynamic>?)?['name']
          as String?;
  final permission = (repoNode['viewerPermission'] as String?) ?? 'ADMIN';
  final allRefs = _collectAllForkRefs(pair, repoNode['refs'], runner);
  final doNotDeleteOids = collectDoNotDeleteOids(
    pair.localRepo,
    runner,
    remoteRefs: [for (final r in allRefs) (name: r.name, oid: r.oid)],
  );

  for (final ref in allRefs) {
    if (!_isAuthoredCandidateRef(
      ref,
      defaultBranch,
      resolvedUser,
      pair.localRepo,
    )) {
      continue;
    }
    candidatesOut.add((
      localRepo: pair.localRepo,
      upstreamRepo: upstreamRepo,
      forkRepo: forkRepo,
      permission: permission,
      branch: ref.name,
      oid: ref.oid,
      committedAt: ref.committedAt,
      doNotDeleteOids: doNotDeleteOids,
    ));
  }
}

List<_RemoteForkRef> _collectAllForkRefs(
  _ForkRepoPair pair,
  Object? initialRefsObj,
  SyncProcessRunner runner,
) {
  final refs = <_RemoteForkRef>[];
  if (initialRefsObj is! Map<String, dynamic>) return refs;
  _appendParsedRefNodes(initialRefsObj['nodes'], refs);

  var pageInfo = initialRefsObj['pageInfo'] as Map<String, dynamic>?;
  var pages = 1;
  while (pageInfo?['hasNextPage'] == true && pages < 5) {
    final cursor = pageInfo?['endCursor'] as String?;
    if (cursor == null || cursor.isEmpty) break;
    final nextObj = _fetchNextForkRefsPage(pair, cursor, runner);
    if (nextObj == null) break;
    _appendParsedRefNodes(nextObj['nodes'], refs);
    pageInfo = nextObj['pageInfo'] as Map<String, dynamic>?;
    pages++;
  }
  return refs;
}

Map<String, dynamic>? _fetchNextForkRefsPage(
  _ForkRepoPair pair,
  String cursor,
  SyncProcessRunner runner,
) {
  final query =
      'query {\n'
      '  repository(owner: ${jsonEncode(pair.forkOwner)}, '
      'name: ${jsonEncode(pair.forkName)}) {\n'
      '    refs(refPrefix: "refs/heads/", first: 100, '
      'after: ${jsonEncode(cursor)}) {\n'
      '      pageInfo { hasNextPage endCursor }\n'
      '      nodes {\n'
      '        name\n'
      '        target {\n'
      '          ... on Commit {\n'
      '            oid\n'
      '            committedDate\n'
      '            author { user { login } }\n'
      '            committer { user { login } }\n'
      '          }\n'
      '        }\n'
      '      }\n'
      '    }\n'
      '  }\n'
      '}';
  final res = runGhWithRetrySync(runner, [
    'api',
    'graphql',
    '-f',
    'query=$query',
  ]);
  final data = _tryDecodeGraphQLData(res.stdout);
  final repo = data?['repository'] as Map<String, dynamic>?;
  return repo?['refs'] as Map<String, dynamic>?;
}

void _appendParsedRefNodes(Object? nodesObj, List<_RemoteForkRef> out) {
  if (nodesObj is! List) return;
  for (final raw in nodesObj.whereType<Map<String, dynamic>>()) {
    final name = raw['name'] as String?;
    final target = raw['target'] as Map<String, dynamic>?;
    final oid = target?['oid'] as String?;
    if (name == null || name.isEmpty || oid == null || oid.isEmpty) continue;
    final author =
        ((target?['author'] as Map<String, dynamic>?)?['user']
                as Map<String, dynamic>?)?['login']
            as String?;
    final committer =
        ((target?['committer'] as Map<String, dynamic>?)?['user']
                as Map<String, dynamic>?)?['login']
            as String?;
    final committedRaw = target?['committedDate'] as String?;
    out.add((
      name: name,
      oid: oid,
      committedAt: committedRaw != null
          ? DateTime.tryParse(committedRaw)
          : null,
      authorLogin: author,
      committerLogin: committer,
    ));
  }
}

bool _isAuthoredCandidateRef(
  _RemoteForkRef ref,
  String? defaultBranch,
  String resolvedUser,
  LocalRepoInfo localRepo,
) {
  if (ref.name == defaultBranch ||
      isProtectedBranch(ref.name) ||
      isDoNotDeleteRef(ref.name)) {
    return false;
  }
  final userLower = resolvedUser.toLowerCase();
  final matchesUser =
      ref.authorLogin?.toLowerCase() == userLower ||
      ref.committerLogin?.toLowerCase() == userLower;
  if (!matchesUser) return false;
  return !localRepo.worktrees.any(
    (wt) =>
        wt.isLocked &&
        (wt.branch == ref.name || wt.branch == 'refs/heads/${ref.name}'),
  );
}

ForkBranchScanResult _classifyForkBranchCandidates({
  required List<_ForkBranchCandidate> candidates,
  required String resolvedUser,
  required Set<String> handledBranchKeys,
  required Set<String> existingTriageBranchKeys,
  required SyncProcessRunner runner,
}) {
  final readyToPrune = <PrunableItem>[];
  final additionalTriage = <TriageItem>[];
  final remoteBranchByKey = <String, String>{};
  final candidateLandedIds = <int>{};

  final unhandled = [
    for (final c in candidates)
      if (!handledBranchKeys.contains(_branchKey(c.upstreamRepo, c.branch))) c,
  ];
  if (unhandled.isEmpty) {
    return (
      readyToPrune: readyToPrune,
      additionalTriage: additionalTriage,
      remoteBranchByKey: remoteBranchByKey,
      candidateLandedIds: candidateLandedIds,
    );
  }

  const batchSize = 25;
  for (var i = 0; i < unhandled.length; i += batchSize) {
    final batch = unhandled.skip(i).take(batchSize).toList();
    final query = _buildUpstreamPrBatchQuery(batch);
    final res = runGhWithRetrySync(runner, [
      'api',
      'graphql',
      '-f',
      'query=$query',
    ]);
    final data = _tryDecodeGraphQLData(res.stdout);
    if (data == null) continue;

    for (var b = 0; b < batch.length; b++) {
      final qNode = data['q$b'];
      if (qNode is! Map<String, dynamic>) continue;
      _classifySingleForkBranch(
        candidate: batch[b],
        qNode: qNode,
        resolvedUser: resolvedUser,
        existingTriageBranchKeys: existingTriageBranchKeys,
        runner: runner,
        readyToPrune: readyToPrune,
        additionalTriage: additionalTriage,
        remoteBranchByKey: remoteBranchByKey,
        candidateLandedIds: candidateLandedIds,
      );
    }
  }

  return (
    readyToPrune: readyToPrune,
    additionalTriage: additionalTriage,
    remoteBranchByKey: remoteBranchByKey,
    candidateLandedIds: candidateLandedIds,
  );
}

String _buildUpstreamPrBatchQuery(List<_ForkBranchCandidate> batch) {
  final buf = StringBuffer('query {\n');
  for (var i = 0; i < batch.length; i++) {
    final parts = batch[i].upstreamRepo.split('/');
    final encOwner = jsonEncode(parts[0]);
    final encName = jsonEncode(parts[1]);
    final encBranch = jsonEncode(batch[i].branch);
    buf.writeln(
      '  q$i: repository(owner: $encOwner, name: $encName) {\n'
      '    url\n'
      '    openPrs: pullRequests(headRefName: $encBranch, states: [OPEN], '
      'first: 5) {\n'
      '      nodes { number author { login } '
      'headRepository { nameWithOwner } }\n'
      '    }\n'
      '    mergedPrs: pullRequests(headRefName: $encBranch, states: [MERGED], '
      'first: 5, orderBy: {field: CREATED_AT, direction: DESC}) {\n'
      '      nodes {\n'
      '        number title url baseRefName headRefOid\n'
      '        createdAt mergedAt closedAt\n'
      '        author { login }\n'
      '        headRepository { nameWithOwner }\n'
      '        mergeCommit { oid }\n'
      '      }\n'
      '    }\n'
      '    closedPrs: pullRequests(headRefName: $encBranch, states: [CLOSED], '
      'first: 5, orderBy: {field: CREATED_AT, direction: DESC}) {\n'
      '      nodes {\n'
      '        number title url headRefOid createdAt closedAt\n'
      '        author { login }\n'
      '        headRepository { nameWithOwner }\n'
      '      }\n'
      '    }\n'
      '  }',
    );
  }
  buf.writeln('}');
  return buf.toString();
}

void _classifySingleForkBranch({
  required _ForkBranchCandidate candidate,
  required Map<String, dynamic> qNode,
  required String resolvedUser,
  required Set<String> existingTriageBranchKeys,
  required SyncProcessRunner runner,
  required List<PrunableItem> readyToPrune,
  required List<TriageItem> additionalTriage,
  required Map<String, String> remoteBranchByKey,
  required Set<int> candidateLandedIds,
}) {
  if (_findMatchingPrNode(qNode['openPrs'], candidate, resolvedUser) != null) {
    return;
  }

  final mergedNode = _findMatchingPrNode(
    qNode['mergedPrs'],
    candidate,
    resolvedUser,
  );
  if (mergedNode != null &&
      _handleMergedForkPr(
        candidate: candidate,
        repoUrl:
            (qNode['url'] as String?) ??
            'https://github.com/${candidate.upstreamRepo}',
        mergedNode: mergedNode,
        runner: runner,
        readyToPrune: readyToPrune,
        additionalTriage: additionalTriage,
        candidateLandedIds: candidateLandedIds,
      )) {
    return;
  }

  if (_tryClassifySafeRedundantBranch(candidate, runner, readyToPrune)) {
    return;
  }

  final key = _branchKey(candidate.upstreamRepo, candidate.branch);
  final remoteSpec = '${candidate.forkRepo}:${candidate.branch}';
  if (existingTriageBranchKeys.contains(key)) {
    remoteBranchByKey[key] = remoteSpec;
    return;
  }

  final closedNode = _findMatchingPrNode(
    qNode['closedPrs'],
    candidate,
    resolvedUser,
  );
  if (closedNode != null) {
    additionalTriage.add(_buildClosedForkPrTriage(candidate, closedNode));
    return;
  }

  additionalTriage.add(_buildUnlinkedForkTriage(candidate));
}

Map<String, dynamic>? _findMatchingPrNode(
  Object? connObj,
  _ForkBranchCandidate candidate,
  String resolvedUser,
) {
  final nodes = (connObj is Map<String, dynamic>) ? connObj['nodes'] : null;
  if (nodes is! List) return null;
  final forkLower = candidate.forkRepo.toLowerCase();
  final userLower = resolvedUser.toLowerCase();
  for (final n in nodes.whereType<Map<String, dynamic>>()) {
    final headRepo =
        (n['headRepository'] as Map<String, dynamic>?)?['nameWithOwner']
            as String?;
    final author = (n['author'] as Map<String, dynamic>?)?['login'] as String?;
    if (headRepo?.toLowerCase() == forkLower ||
        author?.toLowerCase() == userLower) {
      return n;
    }
  }
  return null;
}

bool _handleMergedForkPr({
  required _ForkBranchCandidate candidate,
  required String repoUrl,
  required Map<String, dynamic> mergedNode,
  required SyncProcessRunner runner,
  required List<PrunableItem> readyToPrune,
  required List<TriageItem> additionalTriage,
  required Set<int> candidateLandedIds,
}) {
  final headRefOid = (mergedNode['headRefOid'] as String?) ?? '';
  final mergeOid =
      (mergedNode['mergeCommit'] as Map<String, dynamic>?)?['oid'] as String?;
  final trunk = resolveTrunkBranch(candidate.localRepo);
  final remoteMatchesMerged =
      candidate.oid == headRefOid ||
      candidate.oid == mergeOid ||
      isCommitZeroAheadOfTrunk(
        candidate.localRepo.repoPath,
        trunk,
        candidate.oid,
        runner,
      );
  if (!remoteMatchesMerged) return false;

  final pr = _toLandedPrFromForkNode(candidate, repoUrl, mergedNode);
  if (pr == null) return false;

  final actions = planCleanup(pr, candidate.localRepo, processRunner: runner);
  final matchedWt = findMatchingWorktreeForPr(candidate.localRepo, pr);
  if (matchedWt != null && matchedWt.isLocked) return true;

  final remoteSpec = '${candidate.forkRepo}:${candidate.branch}';
  if (matchedWt != null &&
      isRepoDirtySync(matchedWt.path, processRunner: runner)) {
    additionalTriage.add(
      TriageItem(
        source: 'github',
        repository: pr.repository,
        branch: pr.headRefName,
        worktreePath: matchedWt.path,
        remoteBranch: remoteSpec,
        prOrClNumber: pr.number,
        reason:
            'Worktree ${p.basename(matchedWt.path)} has uncommitted changes',
        createdAt: pr.createdAt,
        updatedAt: pr.mergedAt ?? pr.closedAt,
      ),
    );
    return true;
  }

  final hasLocalSkip = actions.any((a) => a.startsWith('Skip local branch'));
  if (hasLocalSkip) {
    additionalTriage.add(
      TriageItem(
        source: 'github',
        repository: pr.repository,
        branch: pr.headRefName,
        remoteBranch: remoteSpec,
        prOrClNumber: pr.number,
        reason:
            'Merged PR #${pr.number} on `$remoteSpec`, but local branch has '
            'unmerged commits',
        createdAt: pr.createdAt,
        updatedAt: pr.mergedAt ?? pr.closedAt,
      ),
    );
    return true;
  }

  final wtPath = actions.any((a) => a.startsWith('Prune worktree'))
      ? matchedWt?.path
      : null;
  candidateLandedIds.add(pr.number);
  readyToPrune.add(
    PrunableItem(
      source: 'github',
      repository: pr.repository,
      branch: pr.headRefName,
      worktreePath: wtPath,
      remoteBranch: remoteSpec,
      prOrClNumber: pr.number,
      description: 'PR #${pr.number} (merged), remote branch `$remoteSpec`',
      landedPr: pr,
      createdAt: pr.createdAt,
      updatedAt: pr.mergedAt ?? pr.closedAt,
    ),
  );
  return true;
}

LandedPr? _toLandedPrFromForkNode(
  _ForkBranchCandidate candidate,
  String repoUrl,
  Map<String, dynamic> node,
) {
  final number = node['number'] as int?;
  final title = node['title'] as String?;
  final url = node['url'] as String?;
  if (number == null || title == null || url == null) return null;
  return LandedPr(
    number: number,
    title: title,
    url: url,
    repository: candidate.upstreamRepo,
    repoUrl: repoUrl,
    headRefName: candidate.branch,
    headRefOid: (node['headRefOid'] as String?) ?? candidate.oid,
    baseRefName: (node['baseRefName'] as String?) ?? 'main',
    mergeSha: (node['mergeCommit'] as Map<String, dynamic>?)?['oid'] as String?,
    createdAt: _tryParseDate(node['createdAt']),
    mergedAt: _tryParseDate(node['mergedAt']),
    closedAt: _tryParseDate(node['closedAt']),
    headRefExists: true,
    headRepository: candidate.forkRepo,
    headRepoPermission: candidate.permission,
  );
}

bool _tryClassifySafeRedundantBranch(
  _ForkBranchCandidate candidate,
  SyncProcessRunner runner,
  List<PrunableItem> readyToPrune,
) {
  final repo = candidate.localRepo;
  final trunk = resolveTrunkBranch(repo);
  final isArchiveDup = candidate.doNotDeleteOids.contains(candidate.oid);
  final isZeroAhead = isCommitZeroAheadOfTrunk(
    repo.repoPath,
    trunk,
    candidate.oid,
    runner,
  );
  if (!isArchiveDup && !isZeroAhead) return false;

  if (!_isLocalBranchAbsentOrRedundant(candidate, trunk, runner)) {
    return false;
  }

  final remoteSpec = '${candidate.forkRepo}:${candidate.branch}';
  final shortSha = candidate.oid.length > 10
      ? candidate.oid.substring(0, 10)
      : candidate.oid;
  final desc = isArchiveDup
      ? 'Duplicate of preserved DO-NOT-DELETE archive ref ($shortSha), '
            'remote branch `$remoteSpec`'
      : '0 commits ahead of $trunk, remote branch `$remoteSpec`';
  readyToPrune.add(
    PrunableItem(
      source: 'github',
      repository: candidate.upstreamRepo,
      branch: candidate.branch,
      remoteBranch: remoteSpec,
      description: desc,
      updatedAt: candidate.committedAt,
    ),
  );
  return true;
}

bool _isLocalBranchAbsentOrRedundant(
  _ForkBranchCandidate candidate,
  String trunk,
  SyncProcessRunner runner,
) {
  final repo = candidate.localRepo;
  if (repo.currentBranch == candidate.branch) return false;
  final inWorktree = repo.worktrees.any(
    (wt) =>
        wt.path != repo.repoPath &&
        (wt.branch == candidate.branch ||
            wt.branch == 'refs/heads/${candidate.branch}'),
  );
  if (inWorktree) return false;

  final localBranch = repo.branches
      .where((b) => b.name == candidate.branch)
      .firstOrNull;
  if (localBranch == null) return true;
  if (localBranch.sha == candidate.oid) return true;
  if (candidate.doNotDeleteOids.contains(localBranch.sha)) return true;
  return isCommitZeroAheadOfTrunk(
    repo.repoPath,
    trunk,
    localBranch.sha,
    runner,
  );
}

/// Returns `true` when [commitOid] exists locally in [repoPath] and is zero
/// commits ahead of `origin/$trunkBranch`, `upstream/$trunkBranch`, or
/// `$trunkBranch`.
bool isCommitZeroAheadOfTrunk(
  String repoPath,
  String trunkBranch,
  String commitOid,
  SyncProcessRunner runner,
) {
  if (commitOid.isEmpty || !Directory(repoPath).existsSync()) return false;
  for (final ref in [
    'origin/$trunkBranch',
    'upstream/$trunkBranch',
    trunkBranch,
  ]) {
    final res = runner('git', [
      '-C',
      repoPath,
      'rev-list',
      '--count',
      '$ref..$commitOid',
    ]);
    if (res.exitCode == 0 && (res.stdout as String).trim() == '0') {
      return true;
    }
  }
  return false;
}

TriageItem _buildClosedForkPrTriage(
  _ForkBranchCandidate candidate,
  Map<String, dynamic> closedNode,
) {
  final number = closedNode['number'] as int?;
  final remoteSpec = '${candidate.forkRepo}:${candidate.branch}';
  final hasLocal = candidate.localRepo.branches.any(
    (b) => b.name == candidate.branch,
  );
  final localNote = hasLocal ? ' (also has local branch)' : '';
  return TriageItem(
    source: 'github',
    repository: candidate.upstreamRepo,
    branch: candidate.branch,
    remoteBranch: remoteSpec,
    prOrClNumber: number,
    reason:
        'Closed (unmerged) PR #$number on fork branch `$remoteSpec`$localNote',
    createdAt: _tryParseDate(closedNode['createdAt']),
    updatedAt: _tryParseDate(closedNode['closedAt']) ?? candidate.committedAt,
  );
}

TriageItem _buildUnlinkedForkTriage(_ForkBranchCandidate candidate) {
  final remoteSpec = '${candidate.forkRepo}:${candidate.branch}';
  final localBranch = candidate.localRepo.branches
      .where((b) => b.name == candidate.branch)
      .firstOrNull;
  final datePart = candidate.committedAt != null
      ? 'last commit: ${_isoDatePrefix(candidate.committedAt!)}'
      : null;
  final localPart = localBranch != null ? 'also has local branch' : null;
  final details = [localPart, datePart].nonNulls.join('; ');
  final suffix = details.isNotEmpty ? ' ($details)' : '';
  return TriageItem(
    source: 'github',
    repository: candidate.upstreamRepo,
    branch: candidate.branch,
    remoteBranch: remoteSpec,
    reason: 'Unlinked fork branch `$remoteSpec`$suffix',
    updatedAt: candidate.committedAt,
  );
}

String _isoDatePrefix(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-'
    '${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')}';

String _branchKey(String repo, String branch) =>
    '${repo.toLowerCase()}#${branch.toLowerCase()}';

DateTime? _tryParseDate(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) : null;

Map<String, dynamic>? _tryDecodeGraphQLData(Object? stdout) {
  if (stdout is! String || stdout.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(stdout);
    if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      if (data is Map<String, dynamic>) return data;
    }
  } on FormatException {
    return null;
  }
  return null;
}
