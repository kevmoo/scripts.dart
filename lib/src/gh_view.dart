import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/ansi.dart';

import 'gh_view/github_queries.dart';
import 'gh_view/report_renderer.dart';
import 'local_repo_scanner.dart';
import 'process_utils.dart';
import 'shared/gh_args.dart';
import 'shared/gh_pr_ref.dart';

export 'gh_view/github_queries.dart';
export 'gh_view/report_renderer.dart';
export 'local_repo_scanner.dart' show normalizeRepoName;
export 'shared/gh_pr_ref.dart' show GhPrRef;

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

/// Representation of an open GitHub Pull Request.
class GhPr extends GhPrRef {
  final String author;
  final bool isDraft;
  final String state;
  final ReviewDecision reviewDecision;
  final List<String> requestedReviewers;
  final List<String> activeReviewers;
  final List<String> approvedReviewers;
  final int totalReviewThreads;
  final int unresolvedReviewThreads;
  final DateTime? lastAuthorCommentAt;
  final DateTime? lastReviewerActivityAt;
  final MergeableState mergeable;
  final MergeStateStatus mergeStateStatus;
  final bool isInMergeQueue;
  final bool isRepoArchived;
  final CiStatus ciStatus;
  final DateTime updatedAt;
  final LocalBranchStatus? localStatus;
  final String? context;

  const new({
    required super.number,
    required super.title,
    required super.url,
    this.author = '',
    required this.isDraft,
    required this.state,
    required this.reviewDecision,
    required this.requestedReviewers,
    this.activeReviewers = const [],
    this.reviewAuthors,
    this.approvedReviewers = const [],
    required this.totalReviewThreads,
    required this.unresolvedReviewThreads,
    this.lastAuthorCommentAt,
    this.lastCommitAt,
    this.lastReviewerActivityAt,
    required this.mergeable,
    required this.mergeStateStatus,
    required this.isInMergeQueue,
    required super.headRefName,
    required super.headRefOid,
    required super.baseRefName,
    required super.repository,
    required super.repoUrl,
    required this.isRepoArchived,
    required this.ciStatus,
    required this.updatedAt,
    this.localStatus,
    this.context,
  });

  final List<String>? reviewAuthors;
  final DateTime? lastCommitAt;
}

/// Domain status helpers for [GhPr].
extension GhPrStatus on GhPr {
  bool get isApproved => reviewDecision == ReviewDecision.approved;

  bool get isCiPassing => ciStatus.isPassing;

  bool get isMergeableOrQueued =>
      mergeable == MergeableState.mergeable || isInMergeQueue;

  /// True when branch protection/rulesets block merging despite being mergeable and not queued.
  bool get isBlockedMergeState =>
      mergeStateStatus == MergeStateStatus.blocked &&
      mergeable == MergeableState.mergeable &&
      !isInMergeQueue;

  /// True when approved, passing CI, and mergeable, but blocked by branch protection/rulesets.
  bool get isBlockedByProtection =>
      isBlockedMergeState && isApproved && isCiPassing;

  /// Returns human reviewers (from `activeReviewers` or human
  /// `requestedReviewers`), falling back to `requestedReviewers` (which may
  /// include CODEOWNERS teams).
  List<String> get targetReviewers =>
      activeReviewers.isNotEmpty ? activeReviewers : requestedReviewers;

  /// Human reviewers who actually submitted a `PullRequestReview`
  /// ([reviewAuthors], or [activeReviewers] when [reviewAuthors] is omitted)
  /// who are NOT currently in [requestedReviewers] (`reviewRequests`) and have
  /// NOT already approved the PR ([approvedReviewers]).
  ///
  /// When a reviewer submits a non-approving review (`COMMENTED`,
  /// `CHANGES_REQUESTED`, or an `APPROVED` review later `DISMISSED`), GitHub
  /// removes them from `reviewRequests`, dropping the PR from their GitHub
  /// Review Queue (`review-requested:@me`) until re-requested via
  /// `gh pr edit --add-reviewer`.
  List<String> get unrequestedActiveReviewers =>
      (reviewAuthors ?? activeReviewers)
          .where(
            (r) =>
                !requestedReviewers.contains(r) &&
                !approvedReviewers.contains(r),
          )
          .toList();

  /// Latest timestamp of any PR author activity (commit push/author date,
  /// top-level issue comment, or inline review reply).
  DateTime? get lastAuthorActivityAt {
    final commentAt = lastAuthorCommentAt;
    final commitAt = lastCommitAt;
    if (commentAt == null) return commitAt;
    if (commitAt == null) return commentAt;
    return commentAt.isAfter(commitAt) ? commentAt : commitAt;
  }

  /// True when the PR author has pushed a commit or posted a comment/reply
  /// more recently than the latest human reviewer activity.
  bool get hasAuthorRespondedSinceLastReview {
    final reviewerActivity = lastReviewerActivityAt;
    if (reviewerActivity == null) return true;
    final authorActivity = lastAuthorActivityAt;
    if (authorActivity == null) return false;
    return authorActivity.isAfter(reviewerActivity);
  }

  /// True when the PR is open, not a draft, not approved, has no unresolved
  /// review threads, the author has responded or pushed commits since the
  /// latest reviewer activity, and at least one human review author has been
  /// dropped from [requestedReviewers].
  bool get needsReviewReRequest =>
      !isRepoArchived &&
      !isDraft &&
      !isApproved &&
      unresolvedReviewThreads == 0 &&
      hasAuthorRespondedSinceLastReview &&
      unrequestedActiveReviewers.isNotEmpty;

  /// True when the PR author has posted a top-level comment more recently than
  /// the latest reviewer activity.
  bool get isAlreadyPinged {
    final authorComment = lastAuthorCommentAt;
    if (authorComment == null) return false;
    final reviewerActivity = lastReviewerActivityAt;
    if (reviewerActivity == null) return true;
    return authorComment.isAfter(reviewerActivity);
  }
}

/// Local workspace status for a PR branch.
typedef LocalBranchStatus = ({
  String repoPath,
  String branchName,
  String shortSha,
  bool isDirty,
  bool isHeadMatching,
  bool isWorktree,
  String displayStatus,
});

/// Argument configuration for `gh-view`.
class GhViewOptions {
  final String user;
  final String? repo;
  final int limit;
  final int? lastNDays;
  final bool json;
  final bool markdown;
  final bool checkLocal;
  final String? localRoot;
  final String? enricher;

  const new({
    this.user = '@me',
    this.repo,
    this.limit = 50,
    this.lastNDays,
    this.json = false,
    this.markdown = false,
    this.checkLocal = true,
    this.localRoot,
    this.enricher,
  });

  static ArgParser createArgParser() {
    final parser = ArgParser();
    addCommonGhArgs(parser, itemType: 'PRs', lastNDaysAction: 'touched');
    parser
      ..addFlag(
        'local',
        defaultsTo: true,
        help: 'Cross-reference local workspace checkouts and worktrees.',
      )
      ..addOption(
        'local-root',
        help:
            'Base directory for local Git repositories (defaults to ~/github).',
      )
      ..addOption(
        'enricher',
        abbr: 'e',
        help:
            'External command or script to enrich PRs with project/context '
            'metadata.',
      );
    return parser;
  }
}

/// Categorizes PRs into logical operational buckets.
({
  List<GhPr> readyToMerge,
  List<GhPr> actionNeeded,
  List<GhPr> inReview,
  List<GhPr> drafts,
  List<GhPr> archived,
})
categorizePullRequests(List<GhPr> prs) {
  final readyToMerge = <GhPr>[];
  final actionNeeded = <GhPr>[];
  final inReview = <GhPr>[];
  final drafts = <GhPr>[];
  final archived = <GhPr>[];

  for (final pr in prs) {
    if (pr.isRepoArchived) {
      archived.add(pr);
    } else if (pr.isDraft) {
      drafts.add(pr);
    } else if (isReadyToMerge(pr)) {
      readyToMerge.add(pr);
    } else if (_isActionNeeded(pr)) {
      actionNeeded.add(pr);
    } else {
      inReview.add(pr);
    }
  }

  return (
    readyToMerge: readyToMerge,
    actionNeeded: actionNeeded,
    inReview: inReview,
    drafts: drafts,
    archived: archived,
  );
}

bool isReadyToMerge(GhPr pr) {
  final isMergeStateValid =
      pr.mergeStateStatus != MergeStateStatus.blocked || pr.isInMergeQueue;
  return pr.isApproved &&
      pr.isCiPassing &&
      pr.isMergeableOrQueued &&
      isMergeStateValid;
}

bool _isActionNeeded(GhPr pr) {
  final isChangesRequested =
      pr.reviewDecision == ReviewDecision.changesRequested &&
      (pr.requestedReviewers.isEmpty ||
          pr.unrequestedActiveReviewers.isNotEmpty);
  final isCiFailure =
      pr.ciStatus == CiStatus.failure || pr.ciStatus == CiStatus.actionRequired;
  final isConflicting = pr.mergeable == MergeableState.conflicting;
  return isChangesRequested ||
      pr.needsReviewReRequest ||
      isCiFailure ||
      isConflicting ||
      pr.isBlockedByProtection;
}

/// Formats the last touched time relative to [currentTime].
String formatTimeAgo(DateTime dateTime, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final diff = now.difference(dateTime);

  if (diff.isNegative) return 'just now';

  final hours = diff.inHours;
  if (hours < 1) {
    final minutes = diff.inMinutes;
    return minutes <= 1 ? 'just now' : '${minutes}m ago';
  }

  if (hours <= 24) return '${hours}h ago';

  return '${diff.inDays}d ago';
}

/// Color classification for touched timestamps:
/// - `< 7 days`: Green
/// - `< 14 days`: Yellow
/// - `<= 28 days`: Orange
/// - `> 28 days`: Red
enum TouchedColor { green, yellow, orange, red }

/// Returns the color classification for [dateTime] relative to [currentTime].
TouchedColor getTouchedColor(DateTime dateTime, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final diff = now.difference(dateTime);
  if (diff.isNegative) return TouchedColor.green;

  final days = diff.inDays;
  if (days < 7) return TouchedColor.green;
  if (days < 14) return TouchedColor.yellow;
  if (days <= 28) return TouchedColor.orange;
  return TouchedColor.red;
}

/// Formats the touched string with a Markdown color emoji badge.
String formatTouchedMarkdown(DateTime dateTime, {DateTime? currentTime}) {
  final touched = formatTimeAgo(dateTime, currentTime: currentTime);
  final color = getTouchedColor(dateTime, currentTime: currentTime);
  final badge = switch (color) {
    TouchedColor.green => '🟢',
    TouchedColor.yellow => '🟡',
    TouchedColor.orange => '🟠',
    TouchedColor.red => '🔴',
  };
  return '$badge $touched';
}

/// Formats the touched string with ANSI terminal color styling.
String formatTouchedTerminal(DateTime dateTime, {DateTime? currentTime}) {
  final touched = formatTimeAgo(dateTime, currentTime: currentTime);
  final color = getTouchedColor(dateTime, currentTime: currentTime);
  return switch (color) {
    TouchedColor.green => green.wrap(touched) ?? touched,
    TouchedColor.yellow => yellow.wrap(touched) ?? touched,
    TouchedColor.orange => '\x1B[38:5;208m$touched\x1B[0m'.replaceAll(
      '38:5;',
      '38;5;',
    ),
    TouchedColor.red => red.wrap(touched) ?? touched,
  };
}

CiStatus extractCiStatus(String repository, Map<String, dynamic>? commits) {
  final commitNodes = commits?['nodes'] as List<dynamic>?;
  if (commitNodes == null || commitNodes.isEmpty) return CiStatus.none;

  final firstCommit = commitNodes.first as Map<String, dynamic>?;
  final commitObj = firstCommit?['commit'] as Map<String, dynamic>?;
  final statusRollup = commitObj?['statusCheckRollup'] as Map<String, dynamic>?;
  final rawState = statusRollup?['state'] as String? ?? CiStatus.none;

  if (rawState == CiStatus.failure) {
    if (repository.toLowerCase() == 'flutter/flutter' &&
        _isFlutterTreeStatusOnlyFailure(statusRollup)) {
      return CiStatus.treeBroken;
    }
    if (_isActionRequiredOnlyFailure(statusRollup)) {
      return CiStatus.actionRequired;
    }
  }

  return CiStatus(rawState);
}

bool _isActionRequiredOnlyFailure(Map<String, dynamic>? statusRollup) {
  final contexts = statusRollup?['contexts'] as Map<String, dynamic>?;
  final contextNodes = contexts?['nodes'] as List<dynamic>? ?? [];

  var hasActionRequired = false;
  var hasRealFailure = false;

  for (final ctx in contextNodes.whereType<Map<String, dynamic>>()) {
    final raw = (ctx['state'] ?? ctx['conclusion']) as String? ?? '';
    final status = CiStatus(raw);
    if (status == CiStatus.actionRequired) {
      hasActionRequired = true;
    } else if (status.isFailureConclusion) {
      hasRealFailure = true;
    }
  }

  return hasActionRequired && !hasRealFailure;
}

bool _isFlutterTreeStatusOnlyFailure(Map<String, dynamic>? statusRollup) {
  final contexts = statusRollup?['contexts'] as Map<String, dynamic>?;
  final contextNodes = contexts?['nodes'] as List<dynamic>? ?? [];

  var hasRealFailure = false;
  var hasTreeStatusFailure = false;

  for (final ctx in contextNodes.whereType<Map<String, dynamic>>()) {
    final status = _evaluateFlutterContext(ctx);
    if (status == _FlutterContextStatus.realFailure) {
      hasRealFailure = true;
    } else if (status == _FlutterContextStatus.treeStatusFailure) {
      hasTreeStatusFailure = true;
    }
  }

  return hasTreeStatusFailure && !hasRealFailure;
}

enum _FlutterContextStatus { ok, treeStatusFailure, realFailure }

_FlutterContextStatus _evaluateFlutterContext(Map<String, dynamic> ctx) =>
    switch (ctx['__typename']) {
      'StatusContext' => switch (ctx['state']) {
        CiStatus.failure || CiStatus.error =>
          ctx['context'] == 'tree-status'
              ? _FlutterContextStatus.treeStatusFailure
              : _FlutterContextStatus.realFailure,
        _ => _FlutterContextStatus.ok,
      },
      'CheckRun' => switch (ctx['conclusion']) {
        CiStatus.failure ||
        CiStatus.actionRequired ||
        CiStatus.timedOut ||
        CiStatus.cancelled ||
        CiStatus.startupFailure => _FlutterContextStatus.realFailure,
        _ => _FlutterContextStatus.ok,
      },
      _ => _FlutterContextStatus.ok,
    };

/// Function signature for running an external enricher command with stdin JSON
/// payload.
typedef EnricherRunner = Future<String?> Function(
  String command,
  String stdinPayload,
);

/// Default enricher runner invoking `/bin/sh -c <command>` and piping [stdinPayload].
Future<String?> defaultEnricherRunner(
  String command,
  String stdinPayload,
) async {
  try {
    final process = await Process.start('/bin/sh', ['-c', command]);
    process.stdin.write(stdinPayload);
    await process.stdin.flush();
    await process.stdin.close();

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );

    if (exitCode != 0) {
      return null;
    }

    return await stdoutFuture;
  } catch (_) {
    return null;
  }
}

/// Invokes the [enricherCommand] and parses the returned JSON map.
Future<Map<String, String>> fetchEnrichedContext({
  required String enricherCommand,
  required List<GhPr> prs,
  EnricherRunner? enricherRunner,
}) async {
  if (prs.isEmpty) return const {};
  final runner = enricherRunner ?? defaultEnricherRunner;
  final payload = jsonEncode({
    'prs': prs
        .map(
          (pr) => {
            'number': pr.number,
            'title': pr.title,
            'url': pr.url,
            'repository': pr.repository,
            'headRefName': pr.headRefName,
            'baseRefName': pr.baseRefName,
            'isDraft': pr.isDraft,
          },
        )
        .toList(),
  });

  final rawOutput = await runner(enricherCommand, payload);
  if (rawOutput == null || rawOutput.trim().isEmpty) {
    return const {};
  }

  return _parseEnrichedContextJson(rawOutput);
}

Map<String, String> _parseEnrichedContextJson(String rawOutput) {
  try {
    final decoded = jsonDecode(rawOutput);
    if (decoded is! Map) return const {};
    final result = <String, String>{};
    for (final entry in decoded.entries) {
      final key = entry.key.toString().trim();
      final value = entry.value?.toString().trim();
      if (key.isNotEmpty && value != null && value.isNotEmpty) {
        result[key] = value;
      }
    }
    return result;
  } catch (_) {
    return const {};
  }
}

String? _lookupContext(GhPr pr, Map<String, String>? contextMap) {
  if (contextMap == null || contextMap.isEmpty) return null;
  return contextMap[pr.url] ??
      contextMap['${pr.repository}#${pr.number}'] ??
      contextMap['#${pr.number}'];
}

/// Main execution function for `gh-view`.
Future<void> runGhView({
  required GhViewOptions options,
  ProcessRunner? processRunner,
  EnricherRunner? enricherRunner,
  DateTime? now,
}) async {
  final runner = processRunner ?? Process.run;
  final currentTime = now ?? DateTime.now();

  var rawPrs = await fetchOpenPullRequests(
    user: options.user,
    repo: options.repo,
    limit: options.limit,
    lastNDays: options.lastNDays,
    currentTime: currentTime,
    processRunner: runner,
  );

  if (options.lastNDays != null) {
    final cutoff = currentTime.subtract(Duration(days: options.lastNDays!));
    rawPrs = rawPrs.where((pr) => !pr.updatedAt.isBefore(cutoff)).toList();
  }

  Map<String, String>? contextMap;
  if (options.enricher != null && options.enricher!.trim().isNotEmpty) {
    contextMap = await fetchEnrichedContext(
      enricherCommand: options.enricher!,
      prs: rawPrs,
      enricherRunner: enricherRunner,
    );
  }

  final localRepos = options.checkLocal
      ? await _discoverLocalRepositories(options.localRoot)
      : null;
  final prs = await Future.wait(
    rawPrs.map(
      (pr) => _attachLocalStatus(
        pr,
        localRepos,
        context: _lookupContext(pr, contextMap),
        processRunner: runner,
      ),
    ),
  );

  if (options.json) {
    print(renderJsonOutput(prs, currentTime: currentTime));
  } else if (options.markdown) {
    print(renderMarkdownReport(prs, currentTime: currentTime));
  } else {
    print(renderTerminalReport(prs, currentTime: currentTime));
  }
}

Future<List<LocalRepoInfo>?> _discoverLocalRepositories(
  String? customRoot, {
  SyncProcessRunner? processRunner,
}) async {
  final localRootPath =
      customRoot ?? '${Platform.environment['HOME'] ?? ''}/github';
  if (localRootPath.isNotEmpty && Directory(localRootPath).existsSync()) {
    return scanLocalGitRepositories(
      Directory(localRootPath),
      processRunner: processRunner,
    );
  }
  return null;
}

Future<GhPr> _attachLocalStatus(
  GhPr pr,
  List<LocalRepoInfo>? localRepos, {
  String? context,
  ProcessRunner? processRunner,
}) async => GhPr(
  number: pr.number,
  title: pr.title,
  url: pr.url,
  author: pr.author,
  isDraft: pr.isDraft,
  state: pr.state,
  reviewDecision: pr.reviewDecision,
  requestedReviewers: pr.requestedReviewers,
  activeReviewers: pr.activeReviewers,
  totalReviewThreads: pr.totalReviewThreads,
  unresolvedReviewThreads: pr.unresolvedReviewThreads,
  lastAuthorCommentAt: pr.lastAuthorCommentAt,
  lastReviewerActivityAt: pr.lastReviewerActivityAt,
  mergeable: pr.mergeable,
  mergeStateStatus: pr.mergeStateStatus,
  isInMergeQueue: pr.isInMergeQueue,
  headRefName: pr.headRefName,
  headRefOid: pr.headRefOid,
  baseRefName: pr.baseRefName,
  repository: pr.repository,
  repoUrl: pr.repoUrl,
  isRepoArchived: pr.isRepoArchived,
  ciStatus: pr.ciStatus,
  updatedAt: pr.updatedAt,
  localStatus: await _matchLocalStatus(
    pr,
    localRepos,
    processRunner: processRunner,
  ),
  context: context ?? pr.context,
);

Future<LocalBranchStatus?> _matchLocalStatus(
  GhPr pr,
  List<LocalRepoInfo>? localRepos, {
  ProcessRunner? processRunner,
}) async {
  if (localRepos == null || localRepos.isEmpty) return null;

  final repoKey = pr.repository.toLowerCase();
  final matchingRepos = localRepos.where(
    (r) => r.repoNames.any((n) => n.toLowerCase() == repoKey),
  );

  final location = findLocalBranchLocation(matchingRepos, pr);
  if (location == null) return null;

  final shortSha = location.sha.length >= 7
      ? location.sha.substring(0, 7)
      : location.sha;
  final isHeadMatching =
      pr.headRefOid.isNotEmpty &&
      (location.sha == pr.headRefOid || pr.headRefOid.startsWith(location.sha));

  final isDirty = await isRepoDirty(
    location.repoPath,
    processRunner: processRunner,
  );
  var display = isHeadMatching ? '🟢 Synced' : '⚠️ Diverged';
  if (isDirty) display = '$display (Dirty)';

  return (
    repoPath: location.repoPath,
    branchName: pr.headRefName,
    shortSha: shortSha,
    isDirty: isDirty,
    isHeadMatching: isHeadMatching,
    isWorktree: location.isWorktree,
    displayStatus: display,
  );
}
