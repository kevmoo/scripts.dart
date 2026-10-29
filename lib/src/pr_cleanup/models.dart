import '../gh_clean/models.dart';
import '../shared/gh_args.dart';

/// Exception thrown by PR cleanup operations.
class PrCleanupException extends CliException {
  const new(super.message, {super.exitCode = 1});
}

/// An active or hands-off item (open PR or active Gerrit CL).
class ActiveItem {
  final String source; // 'github' or 'gerrit'
  final String repository;
  final int number;
  final String title;
  final String url;
  final String branch;
  final String? worktreePath;
  final String ciBadge;
  final String reviewBadge;
  final String author;
  final bool isDraft;
  final int unresolvedReviewerThreads;
  final int unresolvedAuthorThreads;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastAuthorActivityAt;
  final DateTime? lastReviewerActivityAt;

  const new({
    required this.source,
    required this.repository,
    required this.number,
    required this.title,
    required this.url,
    required this.branch,
    this.worktreePath,
    required this.ciBadge,
    required this.reviewBadge,
    required this.author,
    required this.isDraft,
    this.unresolvedReviewerThreads = 0,
    this.unresolvedAuthorThreads = 0,
    this.createdAt,
    this.updatedAt,
    this.lastAuthorActivityAt,
    this.lastReviewerActivityAt,
  });

  Map<String, dynamic> toJson() => {
    'source': source,
    'repository': repository,
    'number': number,
    'title': title,
    'url': url,
    'branch': branch,
    'worktreePath': worktreePath,
    'ciBadge': ciBadge,
    'reviewBadge': reviewBadge,
    'author': author,
    'isDraft': isDraft,
    'unresolvedReviewerThreads': unresolvedReviewerThreads,
    'unresolvedAuthorThreads': unresolvedAuthorThreads,
    'createdAt': createdAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'lastAuthorActivityAt': lastAuthorActivityAt?.toIso8601String(),
    'lastReviewerActivityAt': lastReviewerActivityAt?.toIso8601String(),
  };
}

/// An item ready to prune immediately (landed PR or merged Gerrit CL).
class PrunableItem {
  final String source; // 'github' or 'gerrit'
  final String repository;
  final String branch;
  final String? worktreePath;
  final String? remoteBranch;
  final int? prOrClNumber;
  final String description;
  final LandedPr? landedPr;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const new({
    required this.source,
    required this.repository,
    required this.branch,
    this.worktreePath,
    this.remoteBranch,
    this.prOrClNumber,
    required this.description,
    this.landedPr,
    this.createdAt,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'source': source,
    'repository': repository,
    'branch': branch,
    'worktreePath': worktreePath,
    'remoteBranch': remoteBranch,
    'prOrClNumber': prOrClNumber,
    'description': description,
    'createdAt': createdAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
  };
}

/// A local worktree safe-kept via `git worktree lock`.
class LockedWorktreeItem {
  final String repository;
  final String worktreePath;
  final String branch;
  final String? lockReason;
  final int? commitsAhead;
  final String? lastCommitSubject;
  final String? lastCommitDate;
  final DateTime? updatedAt;

  const new({
    required this.repository,
    required this.worktreePath,
    required this.branch,
    this.lockReason,
    this.commitsAhead,
    this.lastCommitSubject,
    this.lastCommitDate,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'repository': repository,
    'worktreePath': worktreePath,
    'branch': branch,
    'lockReason': lockReason,
    'commitsAhead': commitsAhead,
    'lastCommitSubject': lastCommitSubject,
    'lastCommitDate': lastCommitDate,
    'updatedAt': updatedAt?.toIso8601String(),
  };
}

/// An item requiring explicit human triage.
class TriageItem {
  final String source; // 'github' or 'gerrit'
  final String repository;
  final String branch;
  final String? worktreePath;
  final int? prOrClNumber;
  final String reason;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const new({
    required this.source,
    required this.repository,
    required this.branch,
    this.worktreePath,
    this.prOrClNumber,
    required this.reason,
    this.createdAt,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'source': source,
    'repository': repository,
    'branch': branch,
    'worktreePath': worktreePath,
    'prOrClNumber': prOrClNumber,
    'reason': reason,
    'createdAt': createdAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
  };
}

/// Aggregated result of a PR and worktree sweep across GitHub and Gerrit.
class PrSweepResult {
  final List<ActiveItem> active;
  final List<PrunableItem> readyToPrune;
  final List<LockedWorktreeItem> lockedWorktrees;
  final List<TriageItem> needsTriage;
  final List<int> candidateLandedIds;
  final DateTime timestamp;

  const new({
    required this.active,
    required this.readyToPrune,
    required this.lockedWorktrees,
    required this.needsTriage,
    required this.candidateLandedIds,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'candidateLandedIds': candidateLandedIds,
    'readyToPrune': [for (final item in readyToPrune) item.toJson()],
    'active': [for (final item in active) item.toJson()],
    'needsTriage': [for (final item in needsTriage) item.toJson()],
    'lockedWorktrees': [for (final item in lockedWorktrees) item.toJson()],
  };
}

/// Result of executing pruning actions on ready-to-prune items.
class PrCleanupApplyResult {
  final int prunedWorktrees;
  final int deletedBranches;
  final int deletedRemoteBranches;
  final List<String> skippedWorktrees;
  final List<String> errors;

  const new({
    this.prunedWorktrees = 0,
    this.deletedBranches = 0,
    this.deletedRemoteBranches = 0,
    this.skippedWorktrees = const [],
    this.errors = const [],
  });

  Map<String, dynamic> toJson() => {
    'prunedWorktrees': prunedWorktrees,
    'deletedBranches': deletedBranches,
    'deletedRemoteBranches': deletedRemoteBranches,
    'skippedWorktrees': skippedWorktrees,
    'errors': errors,
  };
}
