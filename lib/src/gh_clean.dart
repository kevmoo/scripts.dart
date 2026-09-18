import 'dart:convert';
import 'dart:io';

import 'gh_clean/cleanup_executor.dart';
import 'gh_clean/github_queries.dart';
import 'gh_clean/models.dart';
import 'gh_clean/report_formatter.dart';
import 'gh_clean/worktree_scanner.dart';
import 'local_repo_scanner.dart';
import 'process_utils.dart';

export 'gh_clean/cleanup_executor.dart' show executeCleanup;
export 'gh_clean/github_queries.dart'
    show
        buildLandedSearchQuery,
        fetchLandedPrs,
        findCrossAuthorLandedPrs,
        parseLandedPrNode;
export 'gh_clean/models.dart'
    show
        CleanAction,
        GhCleanException,
        GhCleanOptions,
        LandedPr,
        PrCleanResult,
        UnlinkedWorktree,
        planCleanup,
        resolveTrunkBranch;
export 'gh_clean/report_formatter.dart'
    show formatJsonReport, formatMarkdownReport, printTerminalReport;
export 'gh_clean/worktree_scanner.dart' show findUnlinkedWorktrees;
export 'local_repo_scanner.dart'
    show findMatchingWorktree, findMatchingWorktreeForPr;
export 'shared/gh_pr_ref.dart' show GhPrRef;

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

  final matchedWorktreePaths = _collectMatchedWorktreePaths(results);

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

Set<String> _collectMatchedWorktreePaths(List<PrCleanResult> results) => {
  for (final r in results)
    if (r.localRepo != null)
      if (findMatchingWorktreeForPr(r.localRepo!, r.pr) case final wt?) wt.path,
};

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
