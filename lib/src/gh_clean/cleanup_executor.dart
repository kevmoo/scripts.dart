import '../local_repo_scanner.dart';
import '../process_utils.dart';
import 'models.dart';

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
  final trunkBranch = resolveTrunkBranchForPr(pr, localRepo);
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

CleanAction? _executeWorktreePrune(
  LocalRepoInfo localRepo,
  String headBranch,
  String repoShortName,
  SyncProcessRunner runner,
) {
  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt == null) return null;

  if (isDirDirty(matchingWt.path, runner)) {
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
      isProtectedBranch(headBranch) ||
      !localRepo.branches.any((b) => b.name == headBranch)) {
    return null;
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

/// Returns an error string if [headBranch] has unmerged commits not in
/// [trunkBranch] or past [headRefOid], or `null` if safe to delete.
String? _verifyBranchSafeToDelete(
  String repoPath, {
  required String headBranch,
  required String trunkBranch,
  required String? headRefOid,
  required int? prNumber,
  required SyncProcessRunner runner,
}) {
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
      '$ref..$headBranch',
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
    '$headRefOid..$headBranch',
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
