import 'package:args/args.dart';

import '../local_repo_scanner.dart';
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
