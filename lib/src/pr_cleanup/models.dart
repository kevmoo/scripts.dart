import '../gh_clean/models.dart';
import '../shared/gh_args.dart';

/// Exception thrown by PR cleanup operations.
class PrCleanupException extends CliException {
  const new(super.message, {super.exitCode = 1});
}

/// An active or hands-off item (Bucket A).
class BucketAItem {
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
  });

  Map<String, dynamic> toJson() => {
    'source': source,
    'repository': repository,
    'number': number,
    'title': title,
    'url': url,
    'branch': branch,
    if (worktreePath != null) 'worktreePath': worktreePath,
    'ciBadge': ciBadge,
    'reviewBadge': reviewBadge,
    'author': author,
    'isDraft': isDraft,
  };
}

/// An item safe to prune immediately (Bucket B).
class BucketBItem {
  final String source; // 'github' or 'gerrit'
  final String repository;
  final String branch;
  final String? worktreePath;
  final String? remoteBranch;
  final int? prOrClNumber;
  final String description;
  final LandedPr? landedPr;

  const new({
    required this.source,
    required this.repository,
    required this.branch,
    this.worktreePath,
    this.remoteBranch,
    this.prOrClNumber,
    required this.description,
    this.landedPr,
  });

  Map<String, dynamic> toJson() => {
    'source': source,
    'repository': repository,
    'branch': branch,
    if (worktreePath != null) 'worktreePath': worktreePath,
    if (remoteBranch != null) 'remoteBranch': remoteBranch,
    if (prOrClNumber != null) 'prOrClNumber': prOrClNumber,
    'description': description,
  };
}

/// An item requiring explicit human confirmation (Bucket C).
class BucketCItem {
  final String source; // 'github' or 'gerrit'
  final String repository;
  final String branch;
  final String? worktreePath;
  final int? prOrClNumber;
  final String reason;

  const new({
    required this.source,
    required this.repository,
    required this.branch,
    this.worktreePath,
    this.prOrClNumber,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
    'source': source,
    'repository': repository,
    'branch': branch,
    if (worktreePath != null) 'worktreePath': worktreePath,
    if (prOrClNumber != null) 'prOrClNumber': prOrClNumber,
    'reason': reason,
  };
}

/// Aggregated result of a PR and worktree sweep across GitHub and Gerrit.
class PrSweepResult {
  final List<BucketAItem> bucketA;
  final List<BucketBItem> bucketB;
  final List<BucketCItem> bucketC;
  final List<int> candidateLandedIds;
  final DateTime timestamp;

  const new({
    required this.bucketA,
    required this.bucketB,
    required this.bucketC,
    required this.candidateLandedIds,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'candidateLandedIds': candidateLandedIds,
    'bucketA': [for (final item in bucketA) item.toJson()],
    'bucketB': [for (final item in bucketB) item.toJson()],
    'bucketC': [for (final item in bucketC) item.toJson()],
  };
}
