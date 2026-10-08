import '../shared/gh_args.dart';

/// Exception thrown by `gh-view` operations.
class GhViewException extends CliException {
  const new(super.message, {super.exitCode = 1});
}

/// GitHub GraphQL `PullRequestReviewDecision` values.
extension type const ReviewDecision(String value) implements String {
  static const approved = ReviewDecision('APPROVED');
  static const changesRequested = ReviewDecision('CHANGES_REQUESTED');
  static const reviewRequired = ReviewDecision('REVIEW_REQUIRED');
  static const none = ReviewDecision('NONE');
}

/// GitHub StatusCheckRollup / CI rollup state values (plus synthetic `TREE_BROKEN`).
extension type const CiStatus(String value) implements String {
  static const success = CiStatus('SUCCESS');
  static const failure = CiStatus('FAILURE');
  static const error = CiStatus('ERROR');
  static const timedOut = CiStatus('TIMED_OUT');
  static const cancelled = CiStatus('CANCELLED');
  static const startupFailure = CiStatus('STARTUP_FAILURE');
  static const pending = CiStatus('PENDING');
  static const treeBroken = CiStatus('TREE_BROKEN');
  static const actionRequired = CiStatus('ACTION_REQUIRED');
  static const none = CiStatus('NONE');

  bool get isPassing => this == success || this == treeBroken;

  bool get isFailureConclusion =>
      this == failure ||
      this == error ||
      this == timedOut ||
      this == cancelled ||
      this == startupFailure;
}

/// GitHub GraphQL `MergeableState` values.
extension type const MergeableState(String value) implements String {
  static const mergeable = MergeableState('MERGEABLE');
  static const conflicting = MergeableState('CONFLICTING');
  static const unknown = MergeableState('UNKNOWN');
}

/// GitHub GraphQL `MergeStateStatus` values.
extension type const MergeStateStatus(String value) implements String {
  static const blocked = MergeStateStatus('BLOCKED');
  static const clean = MergeStateStatus('CLEAN');
  static const hasHooks = MergeStateStatus('HAS_HOOKS');
  static const unknown = MergeStateStatus('UNKNOWN');
}
