import 'dart:io';

import '../local_repo_scanner.dart';
import '../process_utils.dart';
import 'branch_policy.dart';
import 'models.dart';

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

  final trunk = localRepo.branches
      .where((b) => b.name == trunkBranch)
      .firstOrNull;
  if (!skipSync && (trunk == null || !trunk.isUpToDateWithUpstream)) {
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

  if (headBranch.isEmpty ||
      headBranch == trunkBranch ||
      isProtectedBranch(headBranch) ||
      !localRepo.branches.any((b) => b.name == headBranch)) {
    return;
  }

  final worktreePruned = wtAction != null && wtAction.success;
  final blockingWt = _findBlockingWorktreeForBranch(
    localRepo,
    headBranch,
    worktreePruned: worktreePruned,
  );
  if (blockingWt != null) {
    _recordAction(actions, (
      description: 'Delete local branch `$headBranch`',
      success: false,
      error:
          'Branch `$headBranch` is checked out in worktree at '
          '${blockingWt.path}.',
    ), onProgress);
    return;
  }

  final safetyError = _verifyBranchSafeToDelete(
    localRepo.repoPath,
    headBranch: headBranch,
    trunkBranch: trunkBranch,
    headRefOid: pr.headRefOid,
    prNumber: pr.number,
    runner: runner,
  );
  if (safetyError != null) {
    _recordAction(actions, (
      description: 'Delete local branch `$headBranch`',
      success: false,
      error: safetyError,
    ), onProgress);
    return;
  }

  final res = runner('git', [
    '-C',
    localRepo.repoPath,
    'branch',
    '-D',
    headBranch,
  ]);
  final branchDeleteAction = res.exitCode == 0
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
  _recordAction(actions, branchDeleteAction, onProgress);
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
  if (prNumber != null &&
      runner('git', ['-C', repoPath, 'cat-file', '-e', headRefOid]).exitCode !=
          0) {
    runner('git', ['-C', repoPath, 'fetch', 'origin', 'pull/$prNumber/head']);
  }
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
  if ((logRes.stdout as String).trim().isEmpty) {
    return null;
  }
  runner('git', ['-C', repoPath, 'fetch', 'origin', trunkBranch, '--quiet']);
  final postFetchCount = runner('git', [
    '-C',
    repoPath,
    'rev-list',
    '--count',
    'origin/$trunkBranch..$targetRef',
  ]);
  if (postFetchCount.exitCode == 0 &&
      (postFetchCount.stdout as String).trim() == '0') {
    return null;
  }
  return 'Branch has unpushed commits past PR HEAD ($headRefOid).';
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
