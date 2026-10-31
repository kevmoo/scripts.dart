import 'dart:io';

import 'package:path/path.dart' as p;

import '../gh_clean.dart' show buildLocalRepoMap;
import '../gh_clean/branch_policy.dart';
import '../gh_clean/cleanup_actions.dart';
import '../local_repo_scanner.dart';
import '../process_utils.dart';
import 'fork_branch_scanner.dart';
import 'models.dart';

class _PruneCounts {
  int worktrees = 0;
  int branches = 0;
  int remoteBranches = 0;
}

/// Canonicalizes [rawPath] by expanding `file://` URIs and leading `~`,
/// resolving relative paths against [Directory.current], and resolving
/// existing filesystem symlinks so path comparisons match
/// `git worktree list --porcelain`.
String canonicalizeWorktreePath(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) return '';
  final expanded = _expandWorktreeInput(trimmed);
  final absPath = p.normalize(p.absolute(expanded));
  return _resolveExistingSymlinks(absPath);
}

String _expandWorktreeInput(String trimmed) {
  if (trimmed.startsWith('file://')) {
    final uri = Uri.tryParse(trimmed);
    if (uri != null) return uri.toFilePath();
  }
  final home = Platform.environment['HOME'] ?? '';
  if (home.isEmpty) return trimmed;
  if (trimmed == '~') return home;
  if (trimmed.startsWith('~/')) return '$home/${trimmed.substring(2)}';
  return trimmed;
}

String _resolveExistingSymlinks(String absPath) {
  try {
    final dir = Directory(absPath);
    if (dir.existsSync()) {
      return p.normalize(dir.resolveSymbolicLinksSync());
    }
    final parent = Directory(p.dirname(absPath));
    if (parent.existsSync()) {
      return p.normalize(
        p.join(parent.resolveSymbolicLinksSync(), p.basename(absPath)),
      );
    }
  } on FileSystemException {
    return absPath;
  }
  return absPath;
}

Set<String> _canonicalizeExcludedSet(Iterable<String> excludedWorktrees) => {
  for (final raw in excludedWorktrees)
    if (canonicalizeWorktreePath(raw) case final c when c.isNotEmpty) c,
};

/// Executes ready-to-prune cleanup across GitHub and Gerrit checkouts.
Future<PrCleanupApplyResult> executeReadyToPrune({
  required List<PrunableItem> items,
  required List<LocalRepoInfo> localRepos,
  Iterable<String> excludedWorktrees = const [],
  String? localRoot,
  String? dartSdkPath,
  SyncProcessRunner? syncProcessRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = syncProcessRunner ?? defaultSyncProcessRunner;
  final repoMap = buildLocalRepoMap(localRepos);
  final normalizedExcluded = _canonicalizeExcludedSet(excludedWorktrees);
  final hasGerrit = items.any((i) => i.source == 'gerrit');
  final gerritRepo = hasGerrit
      ? _resolveGerritRepoPath(
          dartSdkPath: dartSdkPath,
          localRoot: localRoot,
          runner: runner,
        )
      : null;

  final counts = _PruneCounts();
  final skippedByCanonical = <String, String>{};
  final errors = <String>[];

  onProgress?.call(
    'Executing ready-to-prune cleanup across GitHub & Gerrit...',
  );

  for (final item in items) {
    final wtPath = _resolveItemWorktreePath(
      item,
      repoMap,
      gerritRepo: gerritRepo,
      runner: runner,
    );
    final canonicalWt = canonicalizeWorktreePath(wtPath ?? '');
    if (wtPath != null && normalizedExcluded.contains(canonicalWt)) {
      final isNew = !skippedByCanonical.containsKey(canonicalWt);
      skippedByCanonical[canonicalWt] ??= wtPath;
      if (isNew) onProgress?.call('  ⏭ Skipped excluded worktree: $wtPath');
      continue;
    }
    if (item.source == 'github') {
      _pruneGithubItem(
        item,
        repoMap,
        normalizedExcluded,
        runner,
        counts,
        errors,
        onProgress,
      );
    } else if (item.source == 'gerrit') {
      _pruneGerritOrRecordError(
        item,
        gerritRepo,
        runner,
        counts,
        errors,
        onProgress,
      );
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
    skippedWorktrees: skippedByCanonical.values.toList(),
    errors: errors,
  );
}

String? _resolveItemWorktreePath(
  PrunableItem item,
  Map<String, LocalRepoInfo> repoMap, {
  required String? gerritRepo,
  required SyncProcessRunner runner,
}) {
  if (item.worktreePath != null && item.worktreePath!.isNotEmpty) {
    return item.worktreePath;
  }
  if (item.source == 'github') {
    return _resolveGithubItemPath(item, repoMap);
  }
  if (item.source == 'gerrit' && gerritRepo != null && item.branch.isNotEmpty) {
    final res = runner('git', ['-C', gerritRepo, 'branch', '--show-current']);
    if (res.exitCode == 0 && (res.stdout as String).trim() == item.branch) {
      return gerritRepo;
    }
  }
  return null;
}

String? _resolveGithubItemPath(
  PrunableItem item,
  Map<String, LocalRepoInfo> repoMap,
) {
  final repo = repoMap[item.repository.toLowerCase()];
  if (repo == null) return null;
  if (item.landedPr != null) {
    final matched = findMatchingWorktreeForPr(repo, item.landedPr!);
    if (matched != null) return matched.path;
  }
  if (item.branch.isNotEmpty && repo.currentBranch == item.branch) {
    return repo.repoPath;
  }
  return null;
}

String? _resolveGerritRepoPath({
  required String? dartSdkPath,
  required String? localRoot,
  required SyncProcessRunner runner,
}) {
  final root =
      localRoot ??
      Platform.environment['GH_LOCAL_ROOT'] ??
      '${Platform.environment['HOME'] ?? ''}/github';
  final base =
      dartSdkPath ??
      Platform.environment['DART_SDK_CHECKOUT'] ??
      '$root/dart-sdk';
  for (final candidate in ['$base/core/main/sdk', base, '$base/.bare']) {
    if (!Directory(candidate).existsSync()) continue;
    final res = runner('git', ['-C', candidate, 'rev-parse', '--git-dir']);
    if (res.exitCode == 0) return candidate;
  }
  return null;
}

void _pruneGithubItem(
  PrunableItem item,
  Map<String, LocalRepoInfo> repoMap,
  Set<String> normalizedExcluded,
  SyncProcessRunner runner,
  _PruneCounts counts,
  List<String> errors,
  void Function(String message)? onProgress,
) {
  final repo = repoMap[item.repository.toLowerCase()];
  if (item.landedPr == null) {
    _pruneBranchOnlyGithubItem(
      item: item,
      localRepo: repo,
      runner: runner,
      counts: counts,
      errors: errors,
      onProgress: onProgress,
    );
    return;
  }
  final skipRepoSync =
      repo != null &&
      normalizedExcluded.contains(canonicalizeWorktreePath(repo.repoPath));
  final cleanActions = executeCleanup(
    item.landedPr!,
    repo,
    skipSync: skipRepoSync,
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

void _pruneBranchOnlyGithubItem({
  required PrunableItem item,
  required LocalRepoInfo? localRepo,
  required SyncProcessRunner runner,
  required _PruneCounts counts,
  required List<String> errors,
  required void Function(String message)? onProgress,
}) {
  if (item.remoteBranch != null && item.remoteBranch!.isNotEmpty) {
    _deleteBranchOnlyRemoteRef(
      remoteSpec: item.remoteBranch!,
      localRepo: localRepo,
      runner: runner,
      counts: counts,
      errors: errors,
      onProgress: onProgress,
    );
  }
  if (localRepo != null && item.branch.isNotEmpty) {
    _deleteBranchOnlyLocalRef(
      branch: item.branch,
      localRepo: localRepo,
      runner: runner,
      counts: counts,
      errors: errors,
      onProgress: onProgress,
    );
  }
}

void _deleteBranchOnlyRemoteRef({
  required String remoteSpec,
  required LocalRepoInfo? localRepo,
  required SyncProcessRunner runner,
  required _PruneCounts counts,
  required List<String> errors,
  required void Function(String message)? onProgress,
}) {
  final colon = remoteSpec.indexOf(':');
  if (colon <= 0 || colon >= remoteSpec.length - 1) {
    errors.add('Invalid remoteBranch spec: $remoteSpec');
    return;
  }
  final forkRepo = remoteSpec.substring(0, colon);
  final branch = remoteSpec.substring(colon + 1);
  if (isProtectedBranch(branch) || isDoNotDeleteRef(branch)) {
    errors.add('Refusing to delete protected remote branch `$remoteSpec`.');
    return;
  }

  final res = runner('gh', [
    'api',
    '-X',
    'DELETE',
    'repos/$forkRepo/git/refs/heads/$branch',
  ]);
  if (res.exitCode != 0) {
    errors.add(
      'Failed to delete remote branch `$remoteSpec`: '
      '${res.stderr.toString().trim()}',
    );
    return;
  }

  counts.remoteBranches++;
  onProgress?.call('  ✓ Deleted remote branch `$remoteSpec`');
  if (localRepo != null) {
    for (final remote in {'origin', forkRepo.split('/').first}) {
      runner('git', [
        'branch',
        '-dr',
        '$remote/$branch',
      ], workingDirectory: localRepo.repoPath);
    }
  }
}

void _deleteBranchOnlyLocalRef({
  required String branch,
  required LocalRepoInfo localRepo,
  required SyncProcessRunner runner,
  required _PruneCounts counts,
  required List<String> errors,
  required void Function(String message)? onProgress,
}) {
  if (isProtectedBranch(branch) || isDoNotDeleteRef(branch)) return;
  final localBranch = localRepo.branches
      .where((b) => b.name == branch)
      .toList();
  if (localBranch.isEmpty) return;

  final isCheckedOut =
      localRepo.currentBranch == branch ||
      localRepo.worktrees.any(
        (wt) =>
            wt.path != localRepo.repoPath &&
            (wt.branch == branch || wt.branch == 'refs/heads/$branch'),
      );
  if (isCheckedOut) {
    errors.add('Skipped local branch `$branch`: checked out in worktree.');
    return;
  }

  final sha = localBranch.first.sha;
  final trunk = resolveTrunkBranch(localRepo);
  final isSafe =
      isCommitZeroAheadOfTrunk(localRepo.repoPath, trunk, sha, runner) ||
      collectDoNotDeleteOids(localRepo, runner).contains(sha);
  if (!isSafe) {
    errors.add('Skipped local branch `$branch`: has unmerged commits.');
    return;
  }

  final res = runner('git', ['-C', localRepo.repoPath, 'branch', '-D', branch]);
  if (res.exitCode == 0) {
    counts.branches++;
    onProgress?.call('  ✓ Deleted local branch `$branch`');
  } else {
    errors.add(
      'Failed to delete local branch `$branch`: '
      '${res.stderr.toString().trim()}',
    );
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

void _pruneGerritOrRecordError(
  PrunableItem item,
  String? gerritRepo,
  SyncProcessRunner runner,
  _PruneCounts counts,
  List<String> errors,
  void Function(String message)? onProgress,
) {
  if (gerritRepo == null) {
    errors.add('Gerrit repository not found for branch ${item.branch}');
    return;
  }
  _pruneGerritItem(item, gerritRepo, runner, counts, errors, onProgress);
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
