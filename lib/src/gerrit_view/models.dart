import '../shared/gh_args.dart';

/// Exception thrown by Gerrit View tool operations.
class GerritViewException extends CliException {
  const new(super.message, {super.exitCode = 1});
}

typedef CommitDetails = ({
  String sha,
  String relativeDate,
  String changeId,
  String rawBody,
});

typedef ThreadSummary = ({
  int totalThreads,
  int unresolvedReviewerLeaves,
  int unresolvedAuthorLeaves,
});

typedef RemoteCL = ({
  int number,
  String changeId,
  String subject,
  String status,
  String currentRevision,
  int currentRevisionNumber,
  String lastAuthorTouch,
  List<String> reviewers,
  List<String> crVotes,
  String cqStatus,
  ThreadSummary threads,
  String nextAction,
});

enum AlignmentState { inSync, contentIdentical, diverged }

typedef AlignmentResult = ({AlignmentState state, String display});

enum ClStatus {
  newCl('NEW'),
  merged('MERGED'),
  abandoned('ABANDONED'),
  unknown('UNKNOWN');

  final String value;
  new(this.value);
  static ClStatus parse(String raw) {
    final normalized = raw.toUpperCase();
    return ClStatus.values.firstWhere(
      (s) => s.value == normalized,
      orElse: () => ClStatus.unknown,
    );
  }
}

typedef CleanupSafety = ({bool isSafe, List<String> unmergedShas});
