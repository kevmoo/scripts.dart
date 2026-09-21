import 'dart:io';

import 'package:args/args.dart';

import 'gh_clean/github_queries.dart';
import 'gh_clean/report_formatter.dart';
import 'local_repo_scanner.dart';
import 'process_utils.dart';
import 'shared/gh_args.dart';
import 'shared/gh_pr_ref.dart';

export 'gh_clean/github_queries.dart';
export 'gh_clean/report_formatter.dart';
export 'local_repo_scanner.dart'
    show findMatchingWorktree, findMatchingWorktreeForPr;
export 'shared/gh_pr_ref.dart' show GhPrRef;

/// Exception thrown by `gh-clean` operations.
class GhCleanException extends CliException {
  const new(super.message, {super.exitCode = 1});
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
          !isProtectedBranch(headRefName)) &&
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

/// Information about a local branch or worktree whose GitHub PR was closed
/// without merging (`is:closed is:unmerged`).
typedef ClosedUnmergedPr = ({
  String repository,
  int number,
  String title,
  String url,
  String branch,
  String headRefOid,
  String localSha,
  String? worktreePath,
  int? commitsAhead,
  bool shaMatchesPrHead,
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

const _trunkCandidates = ['main', 'master', 'trunk', 'dev'];

/// Resolves the default/trunk branch name for [localRepo].
String resolveTrunkBranch(LocalRepoInfo localRepo, {String? preferredTrunk}) {
  if (preferredTrunk != null && isProtectedBranch(preferredTrunk)) {
    return preferredTrunk;
  }
  for (final candidate in _trunkCandidates) {
    if (localRepo.branches.any((b) => b.name == candidate)) {
      return candidate;
    }
  }
  return 'main';
}

bool _isTrunkBranchName(String branch) {
  final lower = branch.toLowerCase().trim();
  const trunkNames = {
    'main',
    'master',
    'trunk',
    'dev',
    'beta',
    'stable',
    'release',
    'head',
  };
  return trunkNames.contains(lower);
}

bool isProtectedBranch(String branch) {
  final lower = branch.toLowerCase().trim();
  if (lower.startsWith('release/') || lower.startsWith('release-')) {
    return true;
  }
  return _isTrunkBranchName(lower);
}

String _resolveTrunkBranchForPr(LandedPr pr, LocalRepoInfo? localRepo) {
  if (localRepo == null) {
    return isProtectedBranch(pr.baseRefName) ? pr.baseRefName : 'main';
  }
  return resolveTrunkBranch(localRepo, preferredTrunk: pr.baseRefName);
}

bool _isDirDirty(String path, SyncProcessRunner runner) => isRepoDirtySync(
  path,
  processRunner: runner,
  includeUntracked: true,
  failClosedOnProcessError: true,
);

bool _isTrunkSynced(LocalRepoInfo localRepo, String trunkBranch) {
  final trunk = localRepo.branches
      .where((b) => b.name == trunkBranch)
      .firstOrNull;
  return trunk != null && trunk.isUpToDateWithUpstream;
}

int _countGitStashes(String repoPath, SyncProcessRunner runner) {
  if (!Directory(repoPath).existsSync()) return 0;
  try {
    final res = runner('git', ['-C', repoPath, 'stash', 'list']);
    if (res.exitCode != 0) return 0;
    final out = (res.stdout as String).trim();
    if (out.isEmpty) return 0;
    return out.split('\n').where((l) => l.trim().isNotEmpty).length;
  } catch (_) {
    return 0;
  }
}

/// Identifies candidate cleanup actions without performing mutations.
List<String> planCleanup(
  LandedPr pr,
  LocalRepoInfo? localRepo, {
  bool skipSync = false,
  bool skipWorktrees = false,
  bool skipRemoteBranches = false,
  SyncProcessRunner? processRunner,
  Map<String, int>? stashCountCache,
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
  final trunkBranch = _resolveTrunkBranchForPr(pr, localRepo);
  final repoShortName = pr.repository.split('/').last;

  String? wtAction;
  if (!skipWorktrees) {
    wtAction = _planWorktreeAction(
      pr,
      localRepo,
      headBranch: headBranch,
      trunkBranch: trunkBranch,
      repoShortName: repoShortName,
      runner: runner,
    );
    if (wtAction != null) actions.add(wtAction);
  }

  if (localRepo.currentBranch == headBranch && headBranch.isNotEmpty) {
    actions.add('Switch branch: `$headBranch` -> `$trunkBranch`');
  }

  final branchAction = _planBranchAction(
    pr,
    localRepo,
    headBranch: headBranch,
    trunkBranch: trunkBranch,
    worktreePruned: wtAction != null && wtAction.startsWith('Prune worktree'),
    runner: runner,
  );
  if (branchAction != null) actions.add(branchAction);

  if (!skipSync && !_isTrunkSynced(localRepo, trunkBranch)) {
    actions.add('Sync `$trunkBranch` to `origin/$trunkBranch`');
  }

  _appendStashNoteIfMutating(
    actions,
    localRepo.repoPath,
    runner,
    stashCountCache: stashCountCache,
  );
  return actions;
}

String _formatWorktreeBranchMismatchReason(
  LocalWorktreeEntry matchingWt,
  String headBranch,
  String repoShortName,
) {
  final folderBranch = matchingWt.expectedBranchFromFolder(repoShortName);
  final isOnHeadBranch =
      matchingWt.branch == headBranch ||
      matchingWt.branch == 'refs/heads/$headBranch';
  if (isOnHeadBranch && folderBranch != null && folderBranch != headBranch) {
    return 'folder matches `$folderBranch`, checked out on `$headBranch`';
  }
  return 'checked out on `${matchingWt.branch}`, expected `$headBranch`';
}

LocalWorktreeEntry? _findBlockingWorktreeForBranch(
  LocalRepoInfo localRepo,
  String headBranch, {
  required bool worktreePruned,
}) {
  if (worktreePruned || headBranch.isEmpty) return null;
  for (final wt in localRepo.worktrees) {
    if (wt.path == localRepo.repoPath) continue;
    if (wt.branch == headBranch || wt.branch == 'refs/heads/$headBranch') {
      return wt;
    }
  }
  return null;
}

String? _planWorktreeAction(
  LandedPr pr,
  LocalRepoInfo localRepo, {
  required String headBranch,
  required String trunkBranch,
  required String repoShortName,
  required SyncProcessRunner runner,
}) {
  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt == null) return null;

  if (!matchingWt.isCheckedOutOnBranch(
    headBranch,
    repoShortName: repoShortName,
    expectedSha: pr.headRefOid,
  )) {
    final reason = _formatWorktreeBranchMismatchReason(
      matchingWt,
      headBranch,
      repoShortName,
    );
    return 'Skip worktree at ${matchingWt.path} ($reason)';
  }
  if (_isDirDirty(matchingWt.path, runner)) {
    return 'Skip worktree at ${matchingWt.path} (has uncommitted changes)';
  }
  final isDetached =
      matchingWt.branch.isEmpty || matchingWt.branch == 'DETACHED';
  final wtSafetyError = _planRefSafetyError(
    localRepo.repoPath,
    headBranch: headBranch,
    trunkBranch: trunkBranch,
    localSha: matchingWt.sha,
    headRefOid: pr.headRefOid,
    prNumber: pr.number,
    runner: runner,
    targetRefOverride: isDetached ? matchingWt.sha : null,
  );
  if (wtSafetyError != null) {
    return 'Skip worktree at ${matchingWt.path} ($wtSafetyError)';
  }
  return 'Prune worktree at ${matchingWt.path}';
}

String? _planBranchAction(
  LandedPr pr,
  LocalRepoInfo localRepo, {
  required String headBranch,
  required String trunkBranch,
  required bool worktreePruned,
  required SyncProcessRunner runner,
}) {
  if (headBranch.isEmpty ||
      headBranch == trunkBranch ||
      isProtectedBranch(headBranch)) {
    return null;
  }
  final localBranch = localRepo.branches
      .where((b) => b.name == headBranch)
      .firstOrNull;
  if (localBranch == null) return null;

  final blockingWt = _findBlockingWorktreeForBranch(
    localRepo,
    headBranch,
    worktreePruned: worktreePruned,
  );
  if (blockingWt != null) {
    return 'Skip local branch `$headBranch` '
        '(checked out in worktree at ${blockingWt.path})';
  }

  final branchSafetyError = _planRefSafetyError(
    localRepo.repoPath,
    headBranch: headBranch,
    trunkBranch: trunkBranch,
    localSha: localBranch.sha,
    headRefOid: pr.headRefOid,
    prNumber: pr.number,
    runner: runner,
  );
  if (branchSafetyError != null) {
    return 'Skip local branch `$headBranch` ($branchSafetyError)';
  }
  return 'Delete local branch `$headBranch`';
}

void _appendStashNoteIfMutating(
  List<String> actions,
  String repoPath,
  SyncProcessRunner runner, {
  Map<String, int>? stashCountCache,
}) {
  final hasLocalMutation = actions.any(
    (a) =>
        a.startsWith('Prune worktree') ||
        a.startsWith('Delete local branch') ||
        a.startsWith('Switch branch'),
  );
  if (!hasLocalMutation) return;
  final stashCount = stashCountCache != null
      ? stashCountCache.putIfAbsent(
          repoPath,
          () => _countGitStashes(repoPath, runner),
        )
      : _countGitStashes(repoPath, runner);
  if (stashCount > 0) {
    actions.add('Note: repository has $stashCount git stash(es)');
  }
}

String? _planRefSafetyError(
  String repoPath, {
  required String headBranch,
  required String trunkBranch,
  required String localSha,
  required String headRefOid,
  required int? prNumber,
  required SyncProcessRunner runner,
  String? targetRefOverride,
}) {
  if (headRefOid.isNotEmpty && localSha == headRefOid) {
    return null;
  }
  if (!Directory(repoPath).existsSync()) {
    return null;
  }
  return _verifyBranchSafeToDelete(
    repoPath,
    headBranch: headBranch,
    trunkBranch: trunkBranch,
    headRefOid: headRefOid,
    prNumber: prNumber,
    runner: runner,
    localSha: targetRefOverride,
  );
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
  final trunkBranch = _resolveTrunkBranchForPr(pr, localRepo);
  final repoShortName = pr.repository.split('/').last;

  CleanAction? wtAction;
  if (!skipWorktrees) {
    wtAction = _executeWorktreePrune(
      localRepo,
      headBranch,
      trunkBranch,
      repoShortName,
      pr.headRefOid,
      runner,
      prNumber: pr.number,
    );
    _recordAction(actions, wtAction, onProgress);
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
      worktreePruned: wtAction != null && wtAction.success,
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

CleanAction? _executeWorktreePrune(
  LocalRepoInfo localRepo,
  String headBranch,
  String trunkBranch,
  String repoShortName,
  String? headRefOid,
  SyncProcessRunner runner, {
  int? prNumber,
}) {
  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt == null) return null;

  if (!matchingWt.isCheckedOutOnBranch(
    headBranch,
    repoShortName: repoShortName,
    expectedSha: headRefOid,
  )) {
    final reason = _formatWorktreeBranchMismatchReason(
      matchingWt,
      headBranch,
      repoShortName,
    );
    return (
      description: 'Pruning worktree at ${matchingWt.path}',
      success: false,
      error: 'Worktree branch mismatch ($reason).',
    );
  }

  if (_isDirDirty(matchingWt.path, runner)) {
    return (
      description: 'Pruning worktree at ${matchingWt.path}',
      success: false,
      error: 'Worktree has uncommitted changes (dirty).',
    );
  }

  if (headRefOid == null ||
      headRefOid.isEmpty ||
      matchingWt.sha != headRefOid) {
    final isDetached =
        matchingWt.branch.isEmpty || matchingWt.branch == 'DETACHED';
    final safetyError = _verifyBranchSafeToDelete(
      localRepo.repoPath,
      headBranch: headBranch,
      trunkBranch: trunkBranch,
      headRefOid: headRefOid,
      prNumber: prNumber,
      runner: runner,
      localSha: isDetached ? matchingWt.sha : null,
    );
    if (safetyError != null) {
      return (
        description: 'Pruning worktree at ${matchingWt.path}',
        success: false,
        error: safetyError,
      );
    }
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
  bool worktreePruned = false,
}) {
  if (headBranch.isEmpty ||
      headBranch == trunkBranch ||
      isProtectedBranch(headBranch)) {
    return null;
  }
  final localBranch = localRepo.branches
      .where((b) => b.name == headBranch)
      .firstOrNull;
  if (localBranch == null) return null;

  final blockingWt = _findBlockingWorktreeForBranch(
    localRepo,
    headBranch,
    worktreePruned: worktreePruned,
  );
  if (blockingWt != null) {
    return (
      description: 'Delete local branch `$headBranch`',
      success: false,
      error:
          'Branch `$headBranch` is checked out in worktree at '
          '${blockingWt.path}.',
    );
  }

  final safetyError = _verifyBranchSafeToDelete(
    localRepo.repoPath,
    headBranch: headBranch,
    trunkBranch: trunkBranch,
    headRefOid: headRefOid,
    prNumber: prNumber,
    runner: runner,
  );
  if (safetyError != null) {
    return (
      description: 'Delete local branch `$headBranch`',
      success: false,
      error: safetyError,
    );
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

/// Returns an error string if [headBranch] (or [localSha]) has unmerged commits
/// not in [trunkBranch] or past [headRefOid], or `null` if safe to delete.
String? _verifyBranchSafeToDelete(
  String repoPath, {
  required String headBranch,
  required String trunkBranch,
  required String? headRefOid,
  required int? prNumber,
  required SyncProcessRunner runner,
  String? localSha,
}) {
  final targetRef = (localSha != null && localSha.isNotEmpty)
      ? localSha
      : headBranch;
  // Check if all commits on the branch are already contained in trunk.
  // For squash-merged PRs where the local branch was advanced onto the squash
  // commit, headRefOid..headBranch is non-empty even though all work has landed
  // on trunk. Checking trunk containment first prevents false positives.
  for (final ref in ['origin/$trunkBranch', trunkBranch]) {
    final countRes = runner('git', [
      '-C',
      repoPath,
      'rev-list',
      '--count',
      '$ref..$targetRef',
    ]);
    if (countRes.exitCode == 0 && (countRes.stdout as String).trim() == '0') {
      return null;
    }
  }

  if (headRefOid == null || headRefOid.isEmpty) {
    return 'Branch has unmerged commits, and PR HEAD could not be verified '
        '(empty headRefOid).';
  }
  _ensureCommitExistsLocally(repoPath, headRefOid, prNumber, runner);
  final logRes = runner('git', [
    '-C',
    repoPath,
    'log',
    '$headRefOid..$targetRef',
    '--oneline',
  ]);
  if (logRes.exitCode != 0) {
    return 'PR HEAD ($headRefOid) is not present locally and could not be '
        'verified.';
  }
  if ((logRes.stdout as String).trim().isNotEmpty) {
    return 'Branch has unpushed commits past PR HEAD ($headRefOid).';
  }
  return null;
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

  final stashCountCache = <String, int>{};
  final results = [
    for (final pr in allLandedPrs)
      _processPr(
        pr,
        repoMap[pr.repository.toLowerCase()],
        options: options,
        runner: runner,
        onProgress: onProgress,
        stashCountCache: stashCountCache,
      ),
  ];

  final allMatchedHeadRefs = {
    ...matchedHeadRefs,
    for (final pr in crossAuthorPrs)
      '${pr.repository}#${pr.headRefName}'.toLowerCase(),
  };

  final matchedWorktreePaths = _collectMatchedWorktreePaths(results);

  onProgress?.call('Checking for closed (unmerged) PR branches & worktrees...');
  final closedUnmergedPrs = await findClosedUnmergedPrs(
    localRepos,
    allMatchedHeadRefs,
    repoFilter: options.repo,
    processRunner: runner,
    onProgress: onProgress,
  );
  if (closedUnmergedPrs.isNotEmpty) {
    onProgress?.call(
      'Found ${closedUnmergedPrs.length} closed (unmerged) PR branch/worktree(s).',
    );
  }

  final closedWorktreePaths = {
    for (final c in closedUnmergedPrs)
      if (c.worktreePath != null) c.worktreePath!,
  };

  onProgress?.call('Checking for worktrees with no associated PR...');
  final unlinkedWorktrees = options.skipWorktrees
      ? const <UnlinkedWorktree>[]
      : await findUnlinkedWorktrees(
          localRepos,
          {...matchedWorktreePaths, ...closedWorktreePaths},
          repoFilter: options.repo,
          processRunner: runner,
          onProgress: onProgress,
        );
  if (unlinkedWorktrees.isNotEmpty) {
    onProgress?.call(
      'Found ${unlinkedWorktrees.length} worktree(s) with no associated PR.',
    );
  }

  outputGhCleanReport(
    results,
    options,
    unlinkedWorktrees: unlinkedWorktrees,
    closedUnmergedPrs: closedUnmergedPrs,
  );
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
  Map<String, int>? stashCountCache,
}) {
  final planned = planCleanup(
    pr,
    localRepo,
    skipSync: options.skipSync,
    skipWorktrees: options.skipWorktrees,
    skipRemoteBranches: options.skipRemoteBranches,
    processRunner: runner,
    stashCountCache: stashCountCache,
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
