import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:meta/meta.dart';

import '../local_repo_scanner.dart';
import '../process_utils.dart';
import '../shared/gh_args.dart';
import '../shared/gh_pr_ref.dart';

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
      !isTrunkBranchName(headRefName) &&
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

@internal
bool isTrunkBranchName(String branch) {
  final lower = branch.toLowerCase().trim();
  const trunkNames = {'main', 'master', 'trunk', 'dev', 'release', 'head'};
  return trunkNames.contains(lower);
}

@internal
bool isProtectedBranch(String branch) {
  final lower = branch.toLowerCase().trim();
  if (lower.startsWith('release/') || lower.startsWith('release-')) {
    return true;
  }
  return isTrunkBranchName(lower);
}

@internal
Iterable<({LocalRepoInfo repo, String owner, String name})> filteredRootRepos(
  List<LocalRepoInfo> localRepos, {
  String? repoFilter,
}) sync* {
  for (final repo in localRepos) {
    if (!isRootGitRepository(Directory(repo.repoPath))) continue;
    if (!_isRepoMatchingFilter(repo, repoFilter)) continue;
    final parsedRepo = _parseRepoOwnerAndName(repo);
    if (parsedRepo == null) continue;
    yield (repo: repo, owner: parsedRepo.owner, name: parsedRepo.name);
  }
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

@internal
Map<String, dynamic>? tryParseGraphQLData(Object? stdout) {
  if (stdout is! String || stdout.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(stdout) as Map<String, dynamic>?;
    return decoded?['data'] as Map<String, dynamic>?;
  } catch (_) {
    return null;
  }
}

@internal
String resolveTrunkBranchForPr(LandedPr pr, LocalRepoInfo? localRepo) {
  if (localRepo == null) {
    return isProtectedBranch(pr.baseRefName) ? pr.baseRefName : 'main';
  }
  return resolveTrunkBranch(localRepo, preferredTrunk: pr.baseRefName);
}

@internal
bool isDirDirty(String path, SyncProcessRunner runner) => isRepoDirtySync(
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
  final trunkBranch = resolveTrunkBranchForPr(pr, localRepo);
  final repoShortName = pr.repository.split('/').last;

  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt != null && !skipWorktrees) {
    if (isDirDirty(matchingWt.path, runner)) {
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
      !isProtectedBranch(headBranch) &&
      localRepo.branches.any((b) => b.name == headBranch)) {
    actions.add('Delete local branch `$headBranch`');
  }

  if (!skipSync && !_isTrunkSynced(localRepo, trunkBranch)) {
    actions.add('Sync `$trunkBranch` to `origin/$trunkBranch`');
  }

  return actions;
}
