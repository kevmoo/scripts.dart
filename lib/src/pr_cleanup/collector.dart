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
  final rootDir = Directory(rootPath);

  onProgress?.call('Starting parallel collection across GitHub & Gerrit...');

  final initialData = await _fetchInitialData(
    options: options,
    dartSdkPath: dartSdkPath,
    syncRunner: syncRunner,
    asyncRunner: asyncRunner,
    onProgress: onProgress,
  );

  final localRepos = scanLocalGitRepositories(
    rootDir,
    processRunner: syncRunner,
  );
  final repoMap = buildLocalRepoMap(localRepos);

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
    repoFilter: options.repo,
    syncRunner: syncRunner,
    onProgress: onProgress,
  );

  final bucketA = <BucketAItem>[];
  final bucketB = <BucketBItem>[];
  final bucketC = <BucketCItem>[];
  final candidateLandedIds = <int>{};

  _processGithubLandedPrs(
    ghCleanResults: ghCleanResults,
    syncRunner: syncRunner,
    bucketB: bucketB,
    bucketC: bucketC,
    candidateLandedIds: candidateLandedIds,
  );

  _processGerritClosedCls(
    gerritAnalysis: initialData.gerrit,
    syncRunner: syncRunner,
    bucketB: bucketB,
    bucketC: bucketC,
    candidateLandedIds: candidateLandedIds,
  );

  _processGithubActivePrs(initialData.activePrs, repoMap, bucketA);
  _processGerritActiveCls(initialData.gerrit, bucketA);
  _processClosedUnmergedAndUnlinked(
    landedResolution.closedUnmergedPrs,
    unlinkedWorktrees,
    bucketC,
  );

  return PrSweepResult(
    bucketA: bucketA,
    bucketB: bucketB,
    bucketC: bucketC,
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
  required String? repoFilter,
  required SyncProcessRunner syncRunner,
  void Function(String message)? onProgress,
}) async {
  final matchedWorktreePaths = _collectMatchedWorktreePaths(ghCleanResults);
  final closedWorktreePaths = {
    for (final c in closedUnmergedPrs)
      if (c.worktreePath != null) c.worktreePath!,
  };

  return findUnlinkedWorktrees(
    localRepos,
    {...matchedWorktreePaths, ...closedWorktreePaths},
    repoFilter: repoFilter,
    processRunner: syncRunner,
    onProgress: onProgress,
  );
}

void _processGithubLandedPrs({
  required List<PrCleanResult> ghCleanResults,
  required SyncProcessRunner syncRunner,
  required List<BucketBItem> bucketB,
  required List<BucketCItem> bucketC,
  required Set<int> candidateLandedIds,
}) {
  for (final result in ghCleanResults) {
    _classifySingleGhCleanResult(
      result,
      syncRunner,
      bucketB,
      bucketC,
      candidateLandedIds,
    );
  }
}

class _GhPlannedDetails {
  final bool hasPruneWorktree;
  final bool hasDeleteBranch;
  final String? worktreePath;
  final String? remoteBranch;

  const new({
    required this.hasPruneWorktree,
    required this.hasDeleteBranch,
    this.worktreePath,
    this.remoteBranch,
  });
}

_GhPlannedDetails _extractGhPlannedActions(PrCleanResult result) {
  var hasPruneWorktree = false;
  var hasDeleteBranch = false;
  String? worktreePath;
  String? remoteBranch;

  for (final action in result.plannedActions) {
    if (action.startsWith('Prune worktree')) {
      hasPruneWorktree = true;
      if (result.localRepo != null) {
        final wt = findMatchingWorktreeForPr(result.localRepo!, result.pr);
        if (wt != null) worktreePath = wt.path;
      }
    } else if (action.startsWith('Delete branch') ||
        action.startsWith('Safe to delete branch')) {
      hasDeleteBranch = true;
    } else if (action.startsWith('Delete remote branch')) {
      remoteBranch = '${result.pr.headRepository}:${result.pr.headRefName}';
    }
  }

  return _GhPlannedDetails(
    hasPruneWorktree: hasPruneWorktree,
    hasDeleteBranch: hasDeleteBranch,
    worktreePath: worktreePath,
    remoteBranch: remoteBranch,
  );
}

void _classifySingleGhCleanResult(
  PrCleanResult result,
  SyncProcessRunner syncRunner,
  List<BucketBItem> bucketB,
  List<BucketCItem> bucketC,
  Set<int> candidateLandedIds,
) {
  final pr = result.pr;
  final planned = _extractGhPlannedActions(result);

  if (planned.worktreePath != null &&
      isRepoDirtySync(planned.worktreePath!, processRunner: syncRunner)) {
    bucketC.add(
      BucketCItem(
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
    bucketB.add(
      BucketBItem(
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
  required List<BucketBItem> bucketB,
  required List<BucketCItem> bucketC,
  required Set<int> candidateLandedIds,
}) {
  if (gerritAnalysis == null) return;

  for (final entry in gerritAnalysis.closedClBranches.entries) {
    _classifySingleGerritClosedCl(
      branchName: entry.key,
      clInfo: entry.value,
      gerritAnalysis: gerritAnalysis,
      syncRunner: syncRunner,
      bucketB: bucketB,
      bucketC: bucketC,
      candidateLandedIds: candidateLandedIds,
    );
  }
}

void _classifySingleGerritClosedCl({
  required String branchName,
  required (int, CommitDetails, ClStatus) clInfo,
  required GerritAnalysisResult gerritAnalysis,
  required SyncProcessRunner syncRunner,
  required List<BucketBItem> bucketB,
  required List<BucketCItem> bucketC,
  required Set<int> candidateLandedIds,
}) {
  final (clNumber, _, status) = clInfo;
  if (status != ClStatus.merged) return;

  final actualRepoRoot = gerritAnalysis.actualRepoRoot;
  final defaultBranch = gerritAnalysis.defaultBranch;
  final safety = checkCleanupSafety(actualRepoRoot, branchName, defaultBranch);
  final wtPath = gerritAnalysis.worktreeBranches[branchName];

  if (!safety.isSafe) {
    bucketC.add(
      BucketCItem(
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
    bucketC.add(
      BucketCItem(
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
  bucketB.add(
    BucketBItem(
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
  List<BucketAItem> bucketA,
) {
  for (final pr in activePrs) {
    final repo = repoMap[pr.repository.toLowerCase()];
    final localWtPath = _findLocalWorktreeForGhPr(repo, pr);
    final ciBadge = _computeCiBadge(pr.ciStatus);
    final reviewBadge = _computeReviewBadge(pr);

    bucketA.add(
      BucketAItem(
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
  List<BucketAItem> bucketA,
) {
  if (gerritAnalysis == null) return;

  for (final cl in gerritAnalysis.remoteCLs.values) {
    if (cl.status != 'NEW') continue;

    final wtPath = _findGerritClWorktree(cl.number, gerritAnalysis);
    final cqBadge = _computeGerritCqBadge(cl.cqStatus);
    final reviewBadge = _computeGerritReviewBadge(cl);
    final lastAuthorAt = DateTime.tryParse(cl.lastAuthorTouch);

    bucketA.add(
      BucketAItem(
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

void _processClosedUnmergedAndUnlinked(
  List<ClosedUnmergedPr> closedUnmergedPrs,
  List<UnlinkedWorktree> unlinkedWorktrees,
  List<BucketCItem> bucketC,
) {
  for (final c in closedUnmergedPrs) {
    if (c.commitsAhead != null && c.commitsAhead! > 0) {
      bucketC.add(
        BucketCItem(
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
    if (u.commitsAhead != null && u.commitsAhead! > 0) {
      final dateSuffix = u.lastCommitDate != null
          ? ' (last commit: ${u.lastCommitDate})'
          : '';
      bucketC.add(
        BucketCItem(
          source: 'github',
          repository: u.repository,
          branch: u.branch,
          worktreePath: u.worktreePath,
          reason:
              'Unlinked worktree `${p.basename(u.worktreePath)}` has '
              '${u.commitsAhead} unpushed commit(s)$dateSuffix',
          updatedAt: _parseWorktreeDatePrefix(u.lastCommitDate),
        ),
      );
    }
  }
}

DateTime? _parseWorktreeDatePrefix(String? rawDate) {
  if (rawDate == null || rawDate.trim().isEmpty) return null;
  final token = rawDate.trim().split(' ').first;
  return DateTime.tryParse(token);
}

Set<String> _collectMatchedWorktreePaths(List<PrCleanResult> results) => {
  for (final r in results)
    if (r.localRepo != null)
      if (findMatchingWorktreeForPr(r.localRepo!, r.pr) case final wt?
          when wt.isCheckedOutOnBranch(
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
    return '🟢 Approved';
  }
  if (cl.reviewers.isNotEmpty) return '⏳ Awaiting Review';
  return '⚪ None';
}
