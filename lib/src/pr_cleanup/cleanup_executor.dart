import 'dart:io';

import 'package:path/path.dart' as p;

import '../gh_clean.dart' show buildLocalRepoMap;
import '../gh_clean/cleanup_actions.dart';
import '../local_repo_scanner.dart';
import '../process_utils.dart';
import 'models.dart';

class _PruneCounts {
  int worktrees = 0;
  int branches = 0;
  int remoteBranches = 0;
}

/// Executes ready-to-prune cleanup across GitHub and Gerrit checkouts.
Future<PrCleanupApplyResult> executeReadyToPrune({
  required List<PrunableItem> items,
  required List<LocalRepoInfo> localRepos,
  Iterable<String> excludedWorktrees = const [],
  String? dartSdkPath,
  SyncProcessRunner? syncProcessRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = syncProcessRunner ?? defaultSyncProcessRunner;
  final repoMap = buildLocalRepoMap(localRepos);
  final gerritRepo = _resolveGerritRepoPath(dartSdkPath);
  final normalizedExcluded = excludedWorktrees
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(p.normalize)
      .toSet();

  final counts = _PruneCounts();
  final skippedWorktrees = <String>[];
  final errors = <String>[];

  onProgress?.call(
    'Executing ready-to-prune cleanup across GitHub & Gerrit...',
  );

  for (final item in items) {
    final wtPath = _resolveItemWorktreePath(item, repoMap);
    if (wtPath != null && normalizedExcluded.contains(p.normalize(wtPath))) {
      skippedWorktrees.add(wtPath);
      onProgress?.call('  ⏭ Skipped excluded worktree: $wtPath');
      continue;
    }
    if (item.source == 'github') {
      _pruneGithubItem(item, repoMap, runner, counts, errors, onProgress);
    } else if (item.source == 'gerrit' && gerritRepo != null) {
      _pruneGerritItem(item, gerritRepo, runner, counts, errors, onProgress);
    }
  }

  onProgress?.call(
    'Pruning complete: ${counts.worktrees} worktree(s) removed, '
    '${counts.branches} local branch(es) deleted, '
    '${counts.remoteBranches} remote branch(es) deleted.',
  );

  return PrCleanupApplyResult(
    prunedWorktrees: counts.worktrees,
    deletedBranches: counts.branches,
    deletedRemoteBranches: counts.remoteBranches,
    skippedWorktrees: skippedWorktrees,
    errors: errors,
  );
}

String? _resolveItemWorktreePath(
  PrunableItem item,
  Map<String, LocalRepoInfo> repoMap,
) {
  if (item.worktreePath != null && item.worktreePath!.isNotEmpty) {
    return item.worktreePath;
  }
  if (item.source == 'github' && item.landedPr != null) {
    final repo = repoMap[item.repository.toLowerCase()];
    if (repo != null) {
      return findMatchingWorktreeForPr(repo, item.landedPr!)?.path;
    }
  }
  return null;
}

String? _resolveGerritRepoPath(String? dartSdkPath) {
  final home = Platform.environment['HOME'] ?? '';
  final defaultSdk = '$home/github/dart-sdk/core/main/sdk';
  final sdkPath = dartSdkPath ?? defaultSdk;
  if (Directory(sdkPath).existsSync()) return sdkPath;
  final fallback = '$home/github/dart-sdk';
  if (Directory(fallback).existsSync()) return fallback;
  return null;
}

void _pruneGithubItem(
  PrunableItem item,
  Map<String, LocalRepoInfo> repoMap,
  SyncProcessRunner runner,
  _PruneCounts counts,
  List<String> errors,
  void Function(String message)? onProgress,
) {
  if (item.landedPr == null) return;
  final repo = repoMap[item.repository.toLowerCase()];
  final cleanActions = executeCleanup(
    item.landedPr!,
    repo,
    processRunner: runner,
    onProgress: onProgress,
  );
  for (final action in cleanActions) {
    if (!action.success) {
      errors.add(action.error ?? action.description);
    } else {
      _tallyAction(action.description, counts);
    }
  }
}

void _tallyAction(String description, _PruneCounts counts) {
  if ((description.startsWith('Pruned ') ||
          description.startsWith('Removed ')) &&
      description.contains('worktree')) {
    counts.worktrees++;
  } else if (description.contains('remote branch')) {
    counts.remoteBranches++;
  } else if ((description.startsWith('Deleted ') ||
          description.startsWith('Removed ')) &&
      description.contains('branch')) {
    counts.branches++;
  }
}

void _pruneGerritItem(
  PrunableItem item,
  String repoPath,
  SyncProcessRunner runner,
  _PruneCounts counts,
  List<String> errors,
  void Function(String message)? onProgress,
) {
  if (item.worktreePath != null) {
    _removeGerritWorktree(
      item.worktreePath!,
      repoPath,
      runner,
      counts,
      errors,
      onProgress,
    );
  }

  if (item.branch.isNotEmpty) {
    _deleteGerritBranch(
      item.branch,
      repoPath,
      runner,
      counts,
      errors,
      onProgress,
    );
  }

  _syncGerritUpstream(repoPath, runner);
}

void _removeGerritWorktree(
  String worktreePath,
  String repoPath,
  SyncProcessRunner runner,
  _PruneCounts counts,
  List<String> errors,
  void Function(String message)? onProgress,
) {
  final res = runner('git', [
    '-C',
    repoPath,
    'worktree',
    'remove',
    worktreePath,
  ]);
  if (res.exitCode == 0) {
    counts.worktrees++;
    onProgress?.call('  ✓ Removed Gerrit worktree: $worktreePath');
  } else {
    errors.add(
      'Failed to remove Gerrit worktree: $worktreePath (${res.stderr})',
    );
  }
}

void _deleteGerritBranch(
  String branch,
  String repoPath,
  SyncProcessRunner runner,
  _PruneCounts counts,
  List<String> errors,
  void Function(String message)? onProgress,
) {
  final res = runner('git', ['-C', repoPath, 'branch', '-D', branch]);
  if (res.exitCode == 0) {
    counts.branches++;
    onProgress?.call('  ✓ Deleted Gerrit branch: $branch');
  } else {
    errors.add('Failed to delete Gerrit branch: $branch (${res.stderr})');
  }

  runner('git', [
    '-C',
    repoPath,
    'config',
    '--unset',
    'branch.$branch.gerritissue',
  ]);
}

void _syncGerritUpstream(String repoPath, SyncProcessRunner runner) {
  runner('git', [
    '-C',
    repoPath,
    'update-ref',
    'refs/remotes/upstream/main',
    'refs/remotes/upstream-sdk/main',
  ]);
}
