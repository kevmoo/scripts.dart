import 'dart:io';

import 'package:path/path.dart' as p;

import '../gerrit_view.dart';
import '../gerrit_view/models.dart';
import '../gh_clean.dart';
import '../gh_clean/fetch_landed_prs.dart';
import '../gh_clean/gh_clean_options.dart';
import '../gh_clean/models.dart';
import '../gh_view.dart';
import '../gh_view/models.dart';
import '../local_repo_scanner.dart';
import '../process_utils.dart';
import 'models.dart';
import 'pr_cleanup_options.dart';

typedef _InitialSweepData = ({
  List<LandedPr> landedPrs,
  List<GhPr> activePrs,
  GerritAnalysisResult? gerrit,
});

/// Collects PR and worktree data across GitHub and Gerrit concurrently.
Future<PrSweepResult> collectPrSweep({
  required PrCleanupOptions options,
  SyncProcessRunner? syncProcessRunner,
  ProcessRunner? asyncProcessRunner,
  void Function(String message)? onProgress,
}) async {
  final syncRunner = syncProcessRunner ?? defaultSyncProcessRunner;
  final asyncRunner = asyncProcessRunner ?? defaultProcessRunner;
  final rootPath = _resolveRootPath(options.localRoot);
  final dartSdkPath = _resolveDartSdkPath(options.dartSdkPath, rootPath);

  onProgress?.call('Starting parallel collection across GitHub & Gerrit...');

  final initialData = await _fetchInitialData(
    options: options,
    dartSdkPath: dartSdkPath,
    syncRunner: syncRunner,
    asyncRunner: asyncRunner,
    onProgress: onProgress,
  );
  final localRepos = scanLocalGitRepositories(
    Directory(rootPath),
    processRunner: syncRunner,
  );

  return _assembleSweepResult(
    initialData: initialData,
    localRepos: localRepos,
    options: options,
    syncRunner: syncRunner,
    onProgress: onProgress,
  );
}

Future<PrSweepResult> _assembleSweepResult({
  required _InitialSweepData initialData,
  required List<LocalRepoInfo> localRepos,
  required PrCleanupOptions options,
  required SyncProcessRunner syncRunner,
  void Function(String message)? onProgress,
}) async {
  final repoMap = buildLocalRepoMap(localRepos);
  final active = <ActiveItem>[];
  _processGithubActivePrs(initialData.activePrs, repoMap, active);
  _processGerritActiveCls(initialData.gerrit, active);
  _sortActiveItems(active);

  final landedResolution = await _resolveAllLandedPrs(
    rawLandedPrs: initialData.landedPrs,
    localRepos: localRepos,
    options: options,
    syncRunner: syncRunner,
    onProgress: onProgress,
  );
  final ghCleanResults = _runGhClean(
    allLandedPrs: landedResolution.allLandedPrs,
    repoMap: repoMap,
    options: options,
    syncRunner: syncRunner,
    onProgress: onProgress,
  );
  final unlinkedWorktrees = await _findUnlinkedWorktrees(
    localRepos: localRepos,
    ghCleanResults: ghCleanResults,
    closedUnmergedPrs: landedResolution.closedUnmergedPrs,
    activeItems: active,
    user: options.user,
    repoFilter: options.repo,
    syncRunner: syncRunner,
    onProgress: onProgress,
  );

  return _buildSweepResult(
    active: active,
    ghCleanResults: ghCleanResults,
    gerrit: initialData.gerrit,
    closedUnmergedPrs: landedResolution.closedUnmergedPrs,
    unlinkedWorktrees: unlinkedWorktrees,
    syncRunner: syncRunner,
  );
}

PrSweepResult _buildSweepResult({
  required List<ActiveItem> active,
  required List<PrCleanResult> ghCleanResults,
  required GerritAnalysisResult? gerrit,
  required List<ClosedUnmergedPr> closedUnmergedPrs,
  required List<UnlinkedWorktree> unlinkedWorktrees,
  required SyncProcessRunner syncRunner,
}) {
  final readyToPrune = <PrunableItem>[];
  final lockedWorktrees = <LockedWorktreeItem>[];
  final needsTriage = <TriageItem>[];
  final candidateLandedIds = <int>{};

  _processGithubLandedPrs(
    ghCleanResults: ghCleanResults,
    syncRunner: syncRunner,
    readyToPrune: readyToPrune,
    needsTriage: needsTriage,
    candidateLandedIds: candidateLandedIds,
  );
  _processGerritClosedCls(
    gerritAnalysis: gerrit,
    syncRunner: syncRunner,
    readyToPrune: readyToPrune,
    needsTriage: needsTriage,
    candidateLandedIds: candidateLandedIds,
  );
  _processClosedUnmergedAndUnlinked(
    closedUnmergedPrs: closedUnmergedPrs,
    unlinkedWorktrees: unlinkedWorktrees,
    lockedWorktrees: lockedWorktrees,
    needsTriage: needsTriage,
  );
  _sortTriageItems(needsTriage);
  _sortLockedWorktrees(lockedWorktrees);

  return PrSweepResult(
    active: active,
    readyToPrune: readyToPrune,
    lockedWorktrees: lockedWorktrees,
    needsTriage: needsTriage,
    candidateLandedIds: candidateLandedIds.toList()..sort(),
    timestamp: DateTime.now(),
  );
}

String _resolveRootPath(String? localRoot) =>
    localRoot ??
    Platform.environment['GH_LOCAL_ROOT'] ??
    '${Platform.environment['HOME']}/github';

String _resolveDartSdkPath(String? dartSdkPath, String rootPath) =>
    dartSdkPath ??
    Platform.environment['DART_SDK_CHECKOUT'] ??
    '$rootPath/dart-sdk';

Future<
  ({
    List<LandedPr> landedPrs,
    List<GhPr> activePrs,
    GerritAnalysisResult? gerrit,
  })
>
_fetchInitialData({
  required PrCleanupOptions options,
  required String dartSdkPath,
  required SyncProcessRunner syncRunner,
  required ProcessRunner asyncRunner,
  void Function(String message)? onProgress,
}) async {
  final landedPrsFuture = fetchLandedPrs(
    user: options.user,
    repo: options.repo,
    lastNDays: options.lastNDays,
    limit: options.limit,
    processRunner: syncRunner,
  );

  final activePrsFuture = fetchOpenPullRequests(
    user: options.user,
    repo: options.repo,
    lastNDays: options.lastNDays,
    limit: options.limit,
    processRunner: asyncRunner,
  );

  final gerritFuture =
      (!options.skipGerrit && Directory(dartSdkPath).existsSync())
      ? analyzeGerritWork(
          gerritRepo: dartSdkPath,
          failSilently: true,
          onProgress: onProgress,
        )
      : Future<GerritAnalysisResult?>.value();

  final results = await Future.wait([
    landedPrsFuture,
    activePrsFuture,
    gerritFuture,
  ]);

  final landedPrs = results[0] as List<LandedPr>;
  final activePrs = results[1] as List<GhPr>;
  final gerrit = results[2] as GerritAnalysisResult?;

  final gerritMsg = gerrit != null
      ? ' Gerrit: ${gerrit.remoteCLs.length} active CL(s).'
      : '';
  onProgress?.call(
    'Retrieved ${landedPrs.length} landed PR(s), '
    '${activePrs.length} active PR(s).$gerritMsg',
  );

  return (landedPrs: landedPrs, activePrs: activePrs, gerrit: gerrit);
}

Future<
  ({List<LandedPr> allLandedPrs, List<ClosedUnmergedPr> closedUnmergedPrs})
>
_resolveAllLandedPrs({
  required List<LandedPr> rawLandedPrs,
  required List<LocalRepoInfo> localRepos,
  required PrCleanupOptions options,
  required SyncProcessRunner syncRunner,
  void Function(String message)? onProgress,
}) async {
  final matchedHeadRefs = {
    for (final pr in rawLandedPrs)
      '${pr.repository}#${pr.headRefName}'.toLowerCase(),
  };

  final crossAuthorPrs = await findCrossAuthorLandedPrs(
    localRepos,
    matchedHeadRefs,
    user: options.user,
    lastNDays: options.lastNDays,
    repoFilter: options.repo,
    processRunner: syncRunner,
    onProgress: onProgress,
  );

  final allLandedPrs = [...rawLandedPrs, ...crossAuthorPrs]
    ..sort((a, b) {
      final repoCmp = a.repository.toLowerCase().compareTo(
        b.repository.toLowerCase(),
      );
      if (repoCmp != 0) return repoCmp;
      return a.number.compareTo(b.number);
    });

  final allMatchedHeadRefs = {
    ...matchedHeadRefs,
    for (final pr in crossAuthorPrs)
      '${pr.repository}#${pr.headRefName}'.toLowerCase(),
  };

  final closedUnmergedPrs = await findClosedUnmergedPrs(
    localRepos,
    allMatchedHeadRefs,
    user: options.user,
    repoFilter: options.repo,
    processRunner: syncRunner,
    onProgress: onProgress,
  );

  return (allLandedPrs: allLandedPrs, closedUnmergedPrs: closedUnmergedPrs);
}

List<PrCleanResult> _runGhClean({
  required List<LandedPr> allLandedPrs,
  required Map<String, LocalRepoInfo> repoMap,
  required PrCleanupOptions options,
  required SyncProcessRunner syncRunner,
  void Function(String message)? onProgress,
}) {
  final stashCountCache = <String, int>{};
  return [
    for (final pr in allLandedPrs)
      processLandedPr(
        pr,
        repoMap[pr.repository.toLowerCase()],
        options: GhCleanOptions(
          user: options.user,
          repo: options.repo,
          limit: options.limit,
          lastNDays: options.lastNDays,
        ),
        runner: syncRunner,
        onProgress: onProgress,
        stashCountCache: stashCountCache,
      ),
  ];
}

Future<List<UnlinkedWorktree>> _findUnlinkedWorktrees({
  required List<LocalRepoInfo> localRepos,
  required List<PrCleanResult> ghCleanResults,
  required List<ClosedUnmergedPr> closedUnmergedPrs,
  required List<ActiveItem> activeItems,
  required String user,
  required String? repoFilter,
  required SyncProcessRunner syncRunner,
  void Function(String message)? onProgress,
}) async {
  final matchedWorktreePaths = _collectMatchedWorktreePaths(ghCleanResults);
  final closedWorktreePaths = {
    for (final c in closedUnmergedPrs)
      if (c.worktreePath != null) c.worktreePath!,
  };
  final activeWorktreePaths = {
    for (final a in activeItems)
      if (a.worktreePath != null) a.worktreePath!,
  };

  return findUnlinkedWorktrees(
    localRepos,
    {...matchedWorktreePaths, ...closedWorktreePaths, ...activeWorktreePaths},
    user: user,
    repoFilter: repoFilter,
    processRunner: syncRunner,
    onProgress: onProgress,
  );
}

void _processGithubLandedPrs({
  required List<PrCleanResult> ghCleanResults,
  required SyncProcessRunner syncRunner,
  required List<PrunableItem> readyToPrune,
  required List<TriageItem> needsTriage,
  required Set<int> candidateLandedIds,
}) {
  for (final result in ghCleanResults) {
    _classifySingleGhCleanResult(
      result,
      syncRunner,
      readyToPrune,
      needsTriage,
      candidateLandedIds,
    );
  }
}

class _GhPlannedDetails {
  final bool hasPruneWorktree;
  final bool hasDeleteBranch;
  final bool isWorktreeLocked;
  final String? worktreePath;
  final String? remoteBranch;

  const new({
    required this.hasPruneWorktree,
    required this.hasDeleteBranch,
    required this.isWorktreeLocked,
    this.worktreePath,
    this.remoteBranch,
  });
}

_GhPlannedDetails _extractGhPlannedActions(PrCleanResult result) {
  var hasPruneWorktree = false;
  var hasDeleteBranch = false;
  String? worktreePath;
  String? remoteBranch;

  final matchedWt = result.localRepo != null
      ? findMatchingWorktreeForPr(result.localRepo!, result.pr)
      : null;
  final isWorktreeLocked = matchedWt != null && matchedWt.isLocked;

  for (final action in result.plannedActions) {
    if (action.startsWith('Prune worktree') && !isWorktreeLocked) {
      hasPruneWorktree = true;
      if (matchedWt != null) worktreePath = matchedWt.path;
    } else if (action.startsWith('Delete branch') ||
        action.startsWith('Delete local branch') ||
        action.startsWith('Safe to delete branch')) {
      if (!isWorktreeLocked) hasDeleteBranch = true;
    } else if (action.startsWith('Delete remote branch')) {
      remoteBranch = '${result.pr.headRepository}:${result.pr.headRefName}';
    }
  }

  return _GhPlannedDetails(
    hasPruneWorktree: hasPruneWorktree,
    hasDeleteBranch: hasDeleteBranch,
    isWorktreeLocked: isWorktreeLocked,
    worktreePath: worktreePath,
    remoteBranch: remoteBranch,
  );
}

void _classifySingleGhCleanResult(
  PrCleanResult result,
  SyncProcessRunner syncRunner,
  List<PrunableItem> readyToPrune,
  List<TriageItem> needsTriage,
  Set<int> candidateLandedIds,
) {
  final pr = result.pr;
  final planned = _extractGhPlannedActions(result);
  if (planned.isWorktreeLocked) return;

  if (planned.worktreePath != null &&
      isRepoDirtySync(planned.worktreePath!, processRunner: syncRunner)) {
    needsTriage.add(
      TriageItem(
        source: 'github',
        repository: pr.repository,
        branch: pr.headRefName,
        worktreePath: planned.worktreePath,
        prOrClNumber: pr.number,
        reason:
            'Worktree ${p.basename(planned.worktreePath!)} has uncommitted '
            'changes',
        createdAt: pr.createdAt,
        updatedAt: pr.mergedAt ?? pr.closedAt,
      ),
    );
    return;
  }

  final isPrunable =
      planned.hasPruneWorktree ||
      planned.hasDeleteBranch ||
      planned.remoteBranch != null;
  if (isPrunable) {
    candidateLandedIds.add(pr.number);
    readyToPrune.add(
      PrunableItem(
        source: 'github',
        repository: pr.repository,
        branch: pr.headRefName,
        worktreePath: planned.worktreePath,
        remoteBranch: planned.remoteBranch,
        prOrClNumber: pr.number,
        description: _formatGithubPrDescription(
          pr,
          worktreePath: planned.worktreePath,
          hasBranch: planned.hasDeleteBranch,
          remoteBranch: planned.remoteBranch,
        ),
        landedPr: pr,
        createdAt: pr.createdAt,
        updatedAt: pr.mergedAt ?? pr.closedAt,
      ),
    );
  }
}

void _processGerritClosedCls({
  required GerritAnalysisResult? gerritAnalysis,
  required SyncProcessRunner syncRunner,
  required List<PrunableItem> readyToPrune,
  required List<TriageItem> needsTriage,
  required Set<int> candidateLandedIds,
}) {
  if (gerritAnalysis == null) return;

  for (final entry in gerritAnalysis.closedClBranches.entries) {
    _classifySingleGerritClosedCl(
      branchName: entry.key,
      clInfo: entry.value,
      gerritAnalysis: gerritAnalysis,
      syncRunner: syncRunner,
      readyToPrune: readyToPrune,
      needsTriage: needsTriage,
      candidateLandedIds: candidateLandedIds,
    );
  }
}

void _classifySingleGerritClosedCl({
  required String branchName,
  required (int, CommitDetails, ClStatus) clInfo,
  required GerritAnalysisResult gerritAnalysis,
  required SyncProcessRunner syncRunner,
  required List<PrunableItem> readyToPrune,
  required List<TriageItem> needsTriage,
  required Set<int> candidateLandedIds,
}) {
  final (clNumber, _, status) = clInfo;
  if (status != ClStatus.merged) return;

  final actualRepoRoot = gerritAnalysis.actualRepoRoot;
  final defaultBranch = gerritAnalysis.defaultBranch;
  final safety = checkCleanupSafety(actualRepoRoot, branchName, defaultBranch);
  final wtPath = gerritAnalysis.worktreeBranches[branchName];

  if (!safety.isSafe) {
    needsTriage.add(
      TriageItem(
        source: 'gerrit',
        repository: 'dart-sdk',
        branch: branchName,
        worktreePath: wtPath,
        prOrClNumber: clNumber,
        reason:
            'Branch has ${safety.unmergedShas.length} unmerged commit(s) '
            'ahead of $defaultBranch',
      ),
    );
    return;
  }

  if (wtPath != null && isRepoDirtySync(wtPath, processRunner: syncRunner)) {
    needsTriage.add(
      TriageItem(
        source: 'gerrit',
        repository: 'dart-sdk',
        branch: branchName,
        worktreePath: wtPath,
        prOrClNumber: clNumber,
        reason:
            'Dart SDK worktree ${p.basename(wtPath)} has uncommitted '
            'changes',
      ),
    );
    return;
  }

  candidateLandedIds.add(clNumber);
  final loc = wtPath != null
      ? ', clean worktree `${p.basename(wtPath)}`'
      : ', local branch `$branchName`';
  readyToPrune.add(
    PrunableItem(
      source: 'gerrit',
      repository: 'dart-sdk',
      branch: branchName,
      worktreePath: wtPath,
      prOrClNumber: clNumber,
      description: 'CL $clNumber (merged)$loc',
    ),
  );
}

void _processGithubActivePrs(
  List<GhPr> activePrs,
  Map<String, LocalRepoInfo> repoMap,
  List<ActiveItem> active,
) {
  for (final pr in activePrs) {
    final repo = repoMap[pr.repository.toLowerCase()];
    final localWtPath = _findLocalWorktreeForGhPr(repo, pr);
    final ciBadge = _computeCiBadge(pr.ciStatus);
    final reviewBadge = _computeReviewBadge(pr);

    active.add(
      ActiveItem(
        source: 'github',
        repository: pr.repository,
        number: pr.number,
        title: pr.title,
        url: pr.url,
        branch: pr.headRefName,
        worktreePath: localWtPath,
        ciBadge: ciBadge,
        reviewBadge: reviewBadge,
        author: pr.author,
        isDraft: pr.isDraft,
        createdAt: pr.createdAt,
        updatedAt: pr.updatedAt,
        lastAuthorActivityAt: pr.lastAuthorActivityAt,
        lastReviewerActivityAt: pr.lastReviewerActivityAt,
      ),
    );
  }
}

String? _findLocalWorktreeForGhPr(LocalRepoInfo? repo, GhPr pr) {
  if (repo == null) return null;
  final wt = findMatchingWorktree(
    repo,
    pr.headRefName,
    pr.repository.split('/').last,
  );
  if (wt != null && wt.path != repo.repoPath) {
    return wt.path;
  }
  return null;
}

void _processGerritActiveCls(
  GerritAnalysisResult? gerritAnalysis,
  List<ActiveItem> active,
) {
  if (gerritAnalysis == null) return;

  for (final cl in gerritAnalysis.remoteCLs.values) {
    if (cl.status != 'NEW') continue;

    final wtPath = _findGerritClWorktree(cl.number, gerritAnalysis);
    final cqBadge = _computeGerritCqBadge(cl.cqStatus);
    final reviewBadge = _computeGerritReviewBadge(cl);
    final lastAuthorAt = DateTime.tryParse(cl.lastAuthorTouch);

    active.add(
      ActiveItem(
        source: 'gerrit',
        repository: 'dart-sdk',
        number: cl.number,
        title: cl.subject,
        url:
            'https://${gerritAnalysis.gerritHost}/c/'
            '${gerritAnalysis.gerritProject}/+/${cl.number}',
        branch: cl.changeId,
        worktreePath: wtPath,
        ciBadge: cqBadge,
        reviewBadge: reviewBadge,
        author: 'self',
        isDraft: false,
        createdAt: cl.createdAt,
        updatedAt: cl.updatedAt ?? lastAuthorAt,
        lastAuthorActivityAt: lastAuthorAt,
      ),
    );
  }
}

String? _findGerritClWorktree(int clNumber, GerritAnalysisResult analysis) {
  for (final entry in analysis.alignedBranches.entries) {
    if (entry.value.$1.number == clNumber) {
      return analysis.worktreeBranches[entry.key];
    }
  }
  return null;
}

void _processClosedUnmergedAndUnlinked({
  required List<ClosedUnmergedPr> closedUnmergedPrs,
  required List<UnlinkedWorktree> unlinkedWorktrees,
  required List<LockedWorktreeItem> lockedWorktrees,
  required List<TriageItem> needsTriage,
}) {
  for (final c in closedUnmergedPrs) {
    if (c.commitsAhead != null && c.commitsAhead! > 0) {
      needsTriage.add(
        TriageItem(
          source: 'github',
          repository: c.repository,
          branch: c.branch,
          worktreePath: c.worktreePath,
          prOrClNumber: c.number,
          reason:
              'Closed (unmerged) PR #${c.number}, has ${c.commitsAhead} '
              'unpushed commit(s) ahead of trunk',
          createdAt: c.createdAt,
          updatedAt: c.closedAt,
        ),
      );
    }
  }

  for (final u in unlinkedWorktrees) {
    if (u.isLocked) {
      lockedWorktrees.add(_toLockedWorktreeItem(u));
    } else if (u.commitsAhead != null && u.commitsAhead! > 0) {
      needsTriage.add(_toUnlinkedTriageItem(u));
    }
  }
}

LockedWorktreeItem _toLockedWorktreeItem(UnlinkedWorktree u) =>
    LockedWorktreeItem(
      repository: u.repository,
      worktreePath: u.worktreePath,
      branch: u.branch,
      lockReason: u.lockReason,
      commitsAhead: u.commitsAhead,
      lastCommitSubject: u.lastCommitSubject,
      lastCommitDate: u.lastCommitDate,
      updatedAt:
          _parseWorktreeDatePrefix(u.lastCommitDate) ??
          _readWorktreeModifiedAt(u.worktreePath),
    );

TriageItem _toUnlinkedTriageItem(UnlinkedWorktree u) {
  final dateSuffix = u.lastCommitDate != null
      ? ' (last commit: ${u.lastCommitDate})'
      : '';
  return TriageItem(
    source: 'github',
    repository: u.repository,
    branch: u.branch,
    worktreePath: u.worktreePath,
    reason:
        'Unlinked worktree `${p.basename(u.worktreePath)}` has '
        '${u.commitsAhead} unpushed commit(s)$dateSuffix',
    updatedAt: _parseWorktreeDatePrefix(u.lastCommitDate),
  );
}

DateTime? _parseWorktreeDatePrefix(String? rawDate) {
  if (rawDate == null || rawDate.trim().isEmpty) return null;
  final token = rawDate.trim().split(' ').first;
  return DateTime.tryParse(token);
}

int _compareDatesDesc(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

void _sortActiveItems(List<ActiveItem> active) {
  active.sort((a, b) {
    final cmp = _compareDatesDesc(
      a.updatedAt ?? a.createdAt,
      b.updatedAt ?? b.createdAt,
    );
    if (cmp != 0) return cmp;
    final repoCmp = a.repository.compareTo(b.repository);
    if (repoCmp != 0) return repoCmp;
    return b.number.compareTo(a.number);
  });
}

void _sortTriageItems(List<TriageItem> needsTriage) {
  needsTriage.sort((a, b) {
    final cmp = _compareDatesDesc(
      a.updatedAt ?? a.createdAt,
      b.updatedAt ?? b.createdAt,
    );
    if (cmp != 0) return cmp;
    final repoCmp = a.repository.compareTo(b.repository);
    if (repoCmp != 0) return repoCmp;
    return a.branch.compareTo(b.branch);
  });
}

void _sortLockedWorktrees(List<LockedWorktreeItem> lockedWorktrees) {
  lockedWorktrees.sort((a, b) {
    final cmp = _compareDatesDesc(a.updatedAt, b.updatedAt);
    if (cmp != 0) return cmp;
    final repoCmp = a.repository.compareTo(b.repository);
    if (repoCmp != 0) return repoCmp;
    return a.branch.compareTo(b.branch);
  });
}

DateTime? _readWorktreeModifiedAt(String worktreePath) {
  try {
    final gitStat = FileStat.statSync('$worktreePath/.git');
    if (gitStat.type != FileSystemEntityType.notFound) {
      return gitStat.modified;
    }
    final dirStat = FileStat.statSync(worktreePath);
    if (dirStat.type != FileSystemEntityType.notFound) {
      return dirStat.modified;
    }
  } catch (_) {
    // Ignore stat errors on non-existent mock paths.
  }
  return null;
}

Set<String> _collectMatchedWorktreePaths(List<PrCleanResult> results) => {
  for (final r in results)
    if (r.localRepo != null)
      if (findMatchingWorktreeForPr(r.localRepo!, r.pr) case final wt?
          when !wt.isLocked &&
              wt.isCheckedOutOnBranch(
                r.pr.headRefName,
                repoShortName: r.pr.repoShortName,
                expectedSha: r.pr.headRefOid,
              ))
        wt.path,
};

String _formatGithubPrDescription(
  LandedPr pr, {
  String? worktreePath,
  required bool hasBranch,
  String? remoteBranch,
}) {
  final parts = <String>[];
  if (worktreePath != null) {
    parts.add('clean worktree `${p.basename(worktreePath)}`');
  }
  if (hasBranch && worktreePath == null) {
    parts.add('local branch `${pr.headRefName}`');
  }
  if (remoteBranch != null) {
    parts.add('remote branch `$remoteBranch`');
  }
  final detail = parts.isEmpty ? 'clean' : parts.join(', ');
  return 'PR #${pr.number} (merged), $detail';
}

String _computeCiBadge(CiStatus status) {
  if (status == CiStatus.success) return '🟢 Passing';
  if (status.isFailureConclusion) return '🔴 Failing';
  if (status == CiStatus.pending) return '🟡 Running';
  if (status == CiStatus.treeBroken) return '🟢 Passing (Tree)';
  if (status == CiStatus.actionRequired) return '⚠️ Action Required';
  return '⚪ None';
}

String _computeReviewBadge(GhPr pr) {
  if (pr.isApproved) return '🟢 Approved';
  if (pr.isDraft) return '⚪ Work in progress';
  if (pr.reviewDecision == ReviewDecision.changesRequested) {
    if (pr.lastAuthorCommentAt != null &&
        pr.lastReviewerActivityAt != null &&
        pr.lastAuthorCommentAt!.isAfter(pr.lastReviewerActivityAt!)) {
      return '🔄 Re-request Review';
    }
    return '🔴 Changes Requested';
  }
  if (pr.requestedReviewers.isNotEmpty) {
    return '⏳ In Review Queue';
  }
  return '⚪ None';
}

String _computeGerritCqBadge(String cqStatus) {
  final s = cqStatus.toUpperCase();
  if (s.contains('PASS') || s.contains('SUCCESS') || s.contains('GREEN')) {
    return '🟢 CQ Green';
  }
  if (s.contains('FAIL')) return '🔴 CQ Failed';
  if (s.contains('RUN') || s.contains('PENDING')) return '🟡 CQ Running';
  return '⚪ CQ None';
}

String _computeGerritReviewBadge(RemoteCL cl) {
  if (cl.crVotes.any((v) => v.endsWith(':-1') || v.endsWith(':-2'))) {
    return '🔴 Changes Requested';
  }
  if (cl.crVotes.any((v) => v.endsWith(':+1') || v.endsWith(':+2'))) {
    if (cl.submittable == false) {
      final reqs = cl.unsatisfiedRequirements.isNotEmpty
          ? 'Needs ${cl.unsatisfiedRequirements.join(', ')}'
          : 'Missing submit requirements';
      return '🟡 Approved ($reqs)';
    }
    return '🟢 Approved';
  }
  if (cl.reviewers.isNotEmpty) return '⏳ Awaiting Review';
  return '⚪ None';
}
