import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import 'local_repo_scanner.dart';
import 'process_utils.dart';
import 'shared/gh_args.dart';
import 'shared/gh_pr_ref.dart';
import 'shared/graphql_utils.dart';

export 'local_repo_scanner.dart' show normalizeRepoName;
export 'shared/gh_pr_ref.dart' show GhPrRef;

/// Exception thrown by `gh-view` operations.
class GhViewException implements Exception {
  final String message;
  final int exitCode;

  new(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
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
  static const pending = CiStatus('PENDING');
  static const treeBroken = CiStatus('TREE_BROKEN');
  static const none = CiStatus('NONE');

  bool get isPassing => this == success || this == treeBroken;
}

/// Representation of an open GitHub Pull Request.
class GhPr extends GhPrRef {
  final String author;
  final bool isDraft;
  final String state;
  final ReviewDecision reviewDecision;
  final List<String> requestedReviewers;
  final List<String> activeReviewers;
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
    required this.totalReviewThreads,
    required this.unresolvedReviewThreads,
    this.lastAuthorCommentAt,
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

  try {
    final decoded = jsonDecode(rawOutput);
    if (decoded is Map) {
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value?.toString().trim();
        if (key.isNotEmpty && value != null && value.isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    }
  } catch (_) {
    // Non-fatal JSON parse failure
  }
  return const {};
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

const _pullRequestsGraphqlQuery = r'''
query($q: String!, $limit: Int!, $cursor: String) {
  search(query: $q, type: ISSUE, first: $limit, after: $cursor) {
    issueCount
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on PullRequest {
        number
        title
        url
        author {
          login
        }
        isDraft
        state
        reviewDecision
        reviewRequests(first: 10) {
          totalCount
          nodes {
            requestedReviewer {
              ... on User {
                login
              }
              ... on Team {
                name
                slug
              }
            }
          }
        }
        reviewThreads(first: 25) {
          totalCount
          nodes {
            isResolved
          }
        }
        reviews(last: 10) {
          nodes {
            author {
              login
            }
            submittedAt
            state
          }
        }
        comments(last: 5) {
          nodes {
            author {
              login
            }
            body
            createdAt
          }
        }
        mergeable
        mergeStateStatus
        isInMergeQueue
        headRefName
        headRefOid
        baseRefName
        updatedAt
        repository {
          nameWithOwner
          url
          isArchived
        }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                state
                contexts(first: 50) {
                  nodes {
                    __typename
                    ... on StatusContext {
                      context
                      state
                    }
                    ... on CheckRun {
                      name
                      conclusion
                      status
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
''';

/// Fetches open PRs via GitHub GraphQL (paginating in chunks of up to 25).
Future<List<GhPr>> fetchOpenPullRequests({
  required String user,
  String? repo,
  int limit = 50,
  int? lastNDays,
  DateTime? currentTime,
  ProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? Process.run;
  final searchQuery = _buildSearchQuery(
    user: user,
    repo: repo,
    lastNDays: lastNDays,
    currentTime: currentTime,
  );

  final nodes = await paginateGraphQLSearch(
    graphqlQuery: _pullRequestsGraphqlQuery,
    searchQuery: searchQuery,
    limit: limit,
    runner: runner,
    exceptionBuilder: (message, {exitCode = 1}) =>
        GhViewException(message, exitCode: exitCode),
  );

  return nodes.map(parsePrNode).whereType<GhPr>().toList();
}

String _buildSearchQuery({
  required String user,
  String? repo,
  int? lastNDays,
  DateTime? currentTime,
}) {
  final buffer = StringBuffer('is:pr is:open');
  if (user.isNotEmpty) buffer.write(' author:$user');
  if (repo != null && repo.isNotEmpty) buffer.write(' repo:$repo');
  if (lastNDays != null) {
    final cutoff = (currentTime ?? DateTime.now()).subtract(
      Duration(days: lastNDays),
    );
    final yyyy = cutoff.year.toString().padLeft(4, '0');
    final mm = cutoff.month.toString().padLeft(2, '0');
    final dd = cutoff.day.toString().padLeft(2, '0');
    buffer.write(' updated:>=$yyyy-$mm-$dd');
  }
  buffer.write(' sort:updated-desc');
  return buffer.toString();
}

/// Parses a single PR node from GraphQL.
GhPr? parsePrNode(Map<String, dynamic> node) {
  final core = GhPrRef.parseCoreFields(node);
  if (core == null) return null;

  final repoMap = node['repository'] as Map<String, dynamic>?;
  final authorMap = node['author'] as Map<String, dynamic>?;
  final prAuthor = authorMap?['login'] as String? ?? '';

  final updatedAtStr = node['updatedAt'] as String?;
  final updatedAt = updatedAtStr != null
      ? DateTime.tryParse(updatedAtStr) ?? DateTime.now()
      : DateTime.now();

  final requested = _extractRequestedReviewers(
    node['reviewRequests'] as Map<String, dynamic>?,
  );
  final reviewerActivity = _extractReviewerActivity(
    node['reviews'] as Map<String, dynamic>?,
    node['comments'] as Map<String, dynamic>?,
    prAuthor,
  );
  final authorComment = _extractAuthorComment(
    node['comments'] as Map<String, dynamic>?,
    prAuthor,
  );

  final lastAuthorCommentAt = authorComment.lastAuthorCommentAt;
  final lastReviewerActivityAt = reviewerActivity.lastReviewerActivityAt;
  final isAlreadyPinged =
      lastAuthorCommentAt != null &&
      (lastReviewerActivityAt == null ||
          lastAuthorCommentAt.isAfter(lastReviewerActivityAt));

  final activeReviewers = _resolveActiveReviewers(
    humanRequested: requested.humanReviewers,
    humanParticipants: reviewerActivity.humanParticipants,
    mentionedUsers: authorComment.mentionedUsers,
    isAlreadyPinged: isAlreadyPinged,
  );

  final threads = _extractReviewThreads(
    node['reviewThreads'] as Map<String, dynamic>?,
  );
  final ciStatus = _extractCiStatus(
    core.repository,
    node['commits'] as Map<String, dynamic>?,
  );

  return GhPr(
    number: core.number,
    title: core.title,
    url: core.url,
    author: prAuthor,
    isDraft: node['isDraft'] as bool? ?? false,
    state: node['state'] as String? ?? 'OPEN',
    reviewDecision: ReviewDecision(
      node['reviewDecision'] as String? ?? ReviewDecision.none,
    ),
    requestedReviewers: requested.allReviewers,
    activeReviewers: activeReviewers,
    totalReviewThreads: threads.total,
    unresolvedReviewThreads: threads.unresolved,
    lastAuthorCommentAt: lastAuthorCommentAt,
    lastReviewerActivityAt: lastReviewerActivityAt,
    mergeable: MergeableState(
      node['mergeable'] as String? ?? MergeableState.unknown,
    ),
    mergeStateStatus: MergeStateStatus(
      node['mergeStateStatus'] as String? ?? MergeStateStatus.unknown,
    ),
    isInMergeQueue: node['isInMergeQueue'] as bool? ?? false,
    headRefName: core.headRefName,
    headRefOid: core.headRefOid,
    baseRefName: core.baseRefName,
    repository: core.repository,
    repoUrl: core.repoUrl,
    isRepoArchived: repoMap?['isArchived'] as bool? ?? false,
    ciStatus: ciStatus,
    updatedAt: updatedAt,
  );
}

({List<String> allReviewers, List<String> humanReviewers})
_extractRequestedReviewers(Map<String, dynamic>? reviewRequestsObj) {
  final requestNodes = reviewRequestsObj?['nodes'] as List<dynamic>? ?? [];
  final allReviewers = <String>[];
  final humanReviewers = <String>[];
  for (final r in requestNodes) {
    if (r is Map<String, dynamic>) {
      final reviewer = r['requestedReviewer'] as Map<String, dynamic>?;
      final userLogin = reviewer?['login'] as String?;
      final teamSlug = reviewer?['slug'] as String?;
      final teamName = reviewer?['name'] as String?;
      final id = userLogin ?? teamSlug ?? teamName;
      if (id != null && id.isNotEmpty) {
        allReviewers.add(id);
        if (userLogin != null && !isBotLogin(userLogin)) {
          humanReviewers.add(userLogin);
        }
      }
    }
  }
  return (allReviewers: allReviewers, humanReviewers: humanReviewers);
}

String? _extractNodeLogin(Map<String, dynamic> item) {
  final authorMap = item['author'] as Map<String, dynamic>?;
  return authorMap?['login'] as String?;
}

DateTime? _extractNodeDateTime(Map<String, dynamic> item, String dateKey) {
  final dateStr = item[dateKey] as String?;
  return dateStr != null ? DateTime.tryParse(dateStr) : null;
}

bool _isHumanReviewer(String? login, String prAuthor) =>
    login != null &&
    login.isNotEmpty &&
    login != prAuthor &&
    !isBotLogin(login);

({DateTime? lastReviewerActivityAt, List<String> humanParticipants})
_extractReviewerActivity(
  Map<String, dynamic>? reviewsObj,
  Map<String, dynamic>? commentsObj,
  String prAuthor,
) {
  DateTime? lastActivity;
  final participants = <String>{};

  void processNodes(List<dynamic>? nodes, String dateKey) {
    for (final item in (nodes ?? const []).whereType<Map<String, dynamic>>()) {
      final login = _extractNodeLogin(item);
      if (!_isHumanReviewer(login, prAuthor)) continue;
      participants.add(login!);
      final dt = _extractNodeDateTime(item, dateKey);
      if (dt != null && (lastActivity == null || dt.isAfter(lastActivity!))) {
        lastActivity = dt;
      }
    }
  }

  processNodes(reviewsObj?['nodes'] as List<dynamic>?, 'submittedAt');
  processNodes(commentsObj?['nodes'] as List<dynamic>?, 'createdAt');
  return (
    lastReviewerActivityAt: lastActivity,
    humanParticipants: participants.toList(),
  );
}

({DateTime? lastAuthorCommentAt, List<String> mentionedUsers})
_extractAuthorComment(Map<String, dynamic>? commentsObj, String prAuthor) {
  if (prAuthor.isEmpty) {
    return (lastAuthorCommentAt: null, mentionedUsers: const []);
  }
  DateTime? lastCommentAt;
  var latestBody = '';
  final nodes = commentsObj?['nodes'] as List<dynamic>? ?? const [];
  for (final item in nodes.whereType<Map<String, dynamic>>()) {
    if (_extractNodeLogin(item) != prAuthor) continue;
    final dt = _extractNodeDateTime(item, 'createdAt');
    if (dt != null && (lastCommentAt == null || dt.isAfter(lastCommentAt))) {
      lastCommentAt = dt;
      latestBody = item['body'] as String? ?? '';
    }
  }

  return (
    lastAuthorCommentAt: lastCommentAt,
    mentionedUsers: _extractMentionedUsers(latestBody, prAuthor),
  );
}

List<String> _extractMentionedUsers(String body, String prAuthor) {
  if (body.isEmpty) return const [];
  final mentioned = <String>{};
  for (final match in RegExp('@([a-zA-Z0-9-]+)').allMatches(body)) {
    final user = match.group(1);
    if (_isHumanReviewer(user, prAuthor)) {
      mentioned.add(user!);
    }
  }
  return mentioned.toList();
}

List<String> _resolveActiveReviewers({
  required List<String> humanRequested,
  required List<String> humanParticipants,
  required List<String> mentionedUsers,
  required bool isAlreadyPinged,
}) {
  if (isAlreadyPinged && mentionedUsers.isNotEmpty) {
    return {...mentionedUsers, ...humanRequested}.toList();
  }
  return {...humanRequested, ...humanParticipants}.toList();
}

({int total, int unresolved}) _extractReviewThreads(
  Map<String, dynamic>? reviewThreadsObj,
) {
  final totalThreads = reviewThreadsObj?['totalCount'] as int? ?? 0;
  final threadNodes = reviewThreadsObj?['nodes'] as List<dynamic>? ?? [];
  var unresolvedThreads = 0;
  for (final t in threadNodes) {
    if (t is Map<String, dynamic> && t['isResolved'] == false) {
      unresolvedThreads++;
    }
  }
  return (total: totalThreads, unresolved: unresolvedThreads);
}

CiStatus _extractCiStatus(String repository, Map<String, dynamic>? commits) {
  final commitNodes = commits?['nodes'] as List<dynamic>?;
  if (commitNodes == null || commitNodes.isEmpty) return CiStatus.none;

  final firstCommit = commitNodes.first as Map<String, dynamic>?;
  final commitObj = firstCommit?['commit'] as Map<String, dynamic>?;
  final statusRollup = commitObj?['statusCheckRollup'] as Map<String, dynamic>?;
  final rawState = statusRollup?['state'] as String? ?? CiStatus.none;

  if (repository.toLowerCase() == 'flutter/flutter' &&
      rawState == CiStatus.failure) {
    if (_isFlutterTreeStatusOnlyFailure(statusRollup)) {
      return CiStatus.treeBroken;
    }
  }

  return CiStatus(rawState);
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

_FlutterContextStatus _evaluateFlutterContext(Map<String, dynamic> ctx) {
  final typename = ctx['__typename'] as String?;
  if (typename == 'StatusContext') {
    final state = ctx['state'] as String? ?? '';
    if (state == CiStatus.failure || state == 'ERROR') {
      final contextName = ctx['context'] as String? ?? '';
      return contextName == 'tree-status'
          ? _FlutterContextStatus.treeStatusFailure
          : _FlutterContextStatus.realFailure;
    }
    return _FlutterContextStatus.ok;
  }
  if (typename == 'CheckRun') {
    final conclusion = ctx['conclusion'] as String? ?? '';
    if (conclusion == CiStatus.failure ||
        conclusion == 'TIMED_OUT' ||
        conclusion == 'CANCELLED') {
      return _FlutterContextStatus.realFailure;
    }
  }
  return _FlutterContextStatus.ok;
}

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
    } else if (_isReadyToMerge(pr)) {
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

bool _isReadyToMerge(GhPr pr) {
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
      pr.requestedReviewers.isEmpty;
  final isCiFailure = pr.ciStatus == CiStatus.failure;
  final isConflicting = pr.mergeable == MergeableState.conflicting;
  return isChangesRequested ||
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
    TouchedColor.orange => '\x1B[38;5;208m$touched\x1B[0m',
    TouchedColor.red => red.wrap(touched) ?? touched,
  };
}

/// Renders human-readable colorized terminal output.
String renderTerminalReport(List<GhPr> prs, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final categorized = categorizePullRequests(prs);

  final buffer = StringBuffer()
    ..writeln('''
======================================================================
${styleBold.wrap('🐙 GITHUB PULL REQUEST OVERVIEW')}
======================================================================''');

  if (prs.isEmpty) {
    buffer.writeln('\nNo open pull requests found. 🎉\n');
    return buffer.toString();
  }

  _writeTerminalSection(
    buffer,
    title: green.wrap(styleBold.wrap('🚀 READY TO MERGE')!)!,
    subtitle: 'Approved by reviewers and all CI checks passing:',
    prs: categorized.readyToMerge,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: red.wrap(
      styleBold.wrap('⚠️  ACTION NEEDED (Blocked / Failing / Conflicts)')!,
    )!,
    subtitle: 'Requires code fixes, rebase, or review feedback resolution:',
    prs: categorized.actionNeeded,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: yellow.wrap(styleBold.wrap('🟡 IN REVIEW QUEUE')!)!,
    subtitle: 'Active PRs awaiting reviewer feedback:',
    prs: categorized.inReview,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: styleDim.wrap(styleBold.wrap('⚪ DRAFTS & WORK IN PROGRESS')!)!,
    subtitle: 'Work-in-progress draft pull requests:',
    prs: categorized.drafts,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: styleDim.wrap(
      styleBold.wrap('📦 ARCHIVED REPOSITORIES (Read-Only)')!,
    )!,
    subtitle: 'Repositories are archived; pull requests cannot be modified:',
    prs: categorized.archived,
    now: now,
  );

  final summary =
      'Total Open: ${prs.length} | '
      '🚀 Ready: ${categorized.readyToMerge.length} | '
      '⚠️ Action: ${categorized.actionNeeded.length} | '
      '🟡 Review: ${categorized.inReview.length} | '
      '⚪ Drafts: ${categorized.drafts.length} | '
      '📦 Archived: ${categorized.archived.length}';

  buffer.writeln('''

----------------------------------------------------------------------
${styleBold.wrap('Summary:')} $summary
----------------------------------------------------------------------''');

  return buffer.toString();
}

void _writeTerminalSection(
  StringBuffer buffer, {
  required String title,
  required String subtitle,
  required List<GhPr> prs,
  required DateTime now,
}) {
  if (prs.isEmpty) return;
  buffer
    ..writeln('\n$title')
    ..writeln(styleDim.wrap('   $subtitle')!);
  for (final pr in prs) {
    _writePrItem(buffer, pr, now);
  }
}

void _writePrItem(StringBuffer buffer, GhPr pr, DateTime now) {
  final prTag =
      styleBold.wrap('${pr.repository}#${pr.number}') ??
      '${pr.repository}#${pr.number}';
  final touched = formatTouchedTerminal(pr.updatedAt, currentTime: now);

  final statusBadges = <String>[];
  if (pr.isRepoArchived) {
    statusBadges.add(styleDim.wrap('[Archived Repo]') ?? '[Archived Repo]');
  }
  if (pr.isDraft) {
    statusBadges.add(styleDim.wrap('[Draft]') ?? '[Draft]');
  }

  statusBadges
    ..add(_formatReviewBadgeTerminal(pr))
    ..add(_formatCiBadgeTerminal(pr));
  if (pr.isInMergeQueue) {
    statusBadges.add(cyan.wrap('🔀 In Merge Queue') ?? '🔀 In Merge Queue');
  }
  if (pr.isBlockedMergeState) {
    statusBadges.add(red.wrap('🧱 Blocked') ?? '🧱 Blocked');
  }
  if (pr.mergeable == MergeableState.conflicting) {
    statusBadges.add(red.wrap('⚠️ Conflicting') ?? '⚠️ Conflicting');
  }

  buffer
    ..writeln('\n  • $prTag: ${pr.title}')
    ..writeln('    URL:     ${pr.url}')
    ..writeln('    Status:  ${statusBadges.join(' | ')}')
    ..writeln('    Branch:  ${pr.headRefName} ➔ ${pr.baseRefName}')
    ..writeln('    Touched: $touched');

  if (pr.context != null && pr.context!.trim().isNotEmpty) {
    buffer.writeln('    Context: ${pr.context!.trim()}');
  }

  if (pr.localStatus != null) {
    final loc = pr.localStatus!;
    final locDesc = p.basename(loc.repoPath);
    final wtTag = loc.isWorktree ? ' (worktree)' : '';
    buffer.writeln(
      '    Local:   ${loc.displayStatus} [$locDesc$wtTag at ${loc.repoPath}]',
    );
  }
}

String _formatReviewBadgeTerminal(GhPr pr) {
  String formatRequested(String label) {
    if (pr.targetReviewers.isNotEmpty) {
      final text = '$label (@${pr.targetReviewers.join(', @')})';
      return yellow.wrap(text) ?? text;
    }
    return yellow.wrap(label) ?? label;
  }

  if (pr.reviewDecision == ReviewDecision.approved) {
    return green.wrap('Approved') ?? 'Approved';
  }
  if (pr.reviewDecision == ReviewDecision.changesRequested) {
    if (pr.targetReviewers.isNotEmpty) {
      return formatRequested('Re-review Requested');
    }
    if (pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0) {
      const text = 'Changes Requested (Resolved: Re-review Needed)';
      return yellow.wrap(text) ?? text;
    }
    return red.wrap('Changes Requested') ?? 'Changes Requested';
  }
  if (pr.reviewDecision == ReviewDecision.reviewRequired) {
    return formatRequested('Review Required');
  }
  return 'No Reviewers';
}

String _formatCiBadgeTerminal(GhPr pr) => switch (pr.ciStatus) {
  CiStatus.success => green.wrap('CI: Passing') ?? 'CI: Passing',
  CiStatus.treeBroken =>
    yellow.wrap('CI: Tree Broken (PR Clean)') ?? 'CI: Tree Broken (PR Clean)',
  CiStatus.failure => red.wrap('CI: Failing') ?? 'CI: Failing',
  CiStatus.pending => yellow.wrap('CI: Pending') ?? 'CI: Pending',
  _ => styleDim.wrap('CI: None') ?? 'CI: None',
};

/// Renders GitHub Flavored Markdown report.
String renderMarkdownReport(List<GhPr> prs, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final categorized = categorizePullRequests(prs);

  const link =
      'file:///usr/local/google/home/kevmoo/github/kevmoo/scripts.dart/bin/gh_view.dart';
  final buffer = StringBuffer()
    ..writeln('# 🐙 GitHub Pull Request Overview Dashboard')
    ..writeln()
    ..writeln(
      'Generated by [`gh-view`]($link) | Scope: `@me` (All GitHub Orgs)',
    )
    ..writeln()
    ..writeln('---')
    ..writeln()
    ..writeln('## 📊 High-Level Summary')
    ..writeln()
    ..writeln('<!-- mdformat off(prevent table wrapping) -->')
    ..writeln('| Metric | Count | Status Description |')
    ..writeln('| :--- | :---: | :--- |')
    ..writeln(
      '| **Total Open PRs** | **${prs.length}** | '
      'Active pull requests across all GitHub organizations |',
    )
    ..writeln(
      '| 🚀 **Ready to Merge** | **${categorized.readyToMerge.length}** | '
      'Approved by reviewers, passing all CI checks, and mergeable |',
    )
    ..writeln(
      '| ⚠️ **Action Needed** | **${categorized.actionNeeded.length}** | '
      'Blocked by failing CI, changes requested, or merge conflicts |',
    )
    ..writeln(
      '| 🟡 **In Review Queue** | **${categorized.inReview.length}** | '
      'Active non-draft PRs with green/pending CI awaiting review |',
    )
    ..writeln(
      '| ⚪ **Drafts & WIP** | **${categorized.drafts.length}** | '
      'Work-in-progress draft pull requests |',
    )
    ..writeln(
      '| 📦 **Archived Repositories** | **${categorized.archived.length}** | '
      'Pull requests in archived/read-only repositories |',
    )
    ..writeln('<!-- mdformat on -->')
    ..writeln();

  if (prs.isEmpty) {
    buffer.writeln('No open pull requests found. 🎉\n');
    return buffer.toString();
  }

  _writeMarkdownSection(
    buffer,
    title: '## 🚀 1. Ready to Merge (Approved + Green CI + Mergeable)',
    prs: categorized.readyToMerge,
    now: now,
  );

  _writeMarkdownSection(
    buffer,
    title: '## ⚠️ 2. Action Needed (Blocked / Failing CI / Conflicts / Changes Requested)',
    prs: categorized.actionNeeded,
    now: now,
  );

  _writeMarkdownSection(
    buffer,
    title: '## 🟡 3. In Review Queue (Green CI + Active Review)',
    prs: categorized.inReview,
    now: now,
  );

  _writeMarkdownSection(
    buffer,
    title:
        '## ⚪ 4. Drafts & Work In Progress (${categorized.drafts.length} PRs)',
    prs: categorized.drafts,
    now: now,
  );

  _writeMarkdownSection(
    buffer,
    title:
        '## 📦 5. Archived Repositories (Read-Only) '
        '(${categorized.archived.length} PRs)',
    prs: categorized.archived,
    now: now,
  );

  return buffer.toString();
}

void _writeMarkdownSection(
  StringBuffer buffer, {
  required String title,
  required List<GhPr> prs,
  required DateTime now,
}) {
  if (prs.isEmpty) return;
  const tableHeader = '''
<!-- mdformat off(prevent table wrapping) -->
| PR & Repository | Branch & Local Mapping | Review & CI Status | Last Touched | Action / Ping Status |
| :--- | :--- | :--- | :--- | :--- |''';

  buffer
    ..writeln(title)
    ..writeln()
    ..writeln(tableHeader);
  for (final pr in prs) {
    _writeMarkdownPrRow(buffer, pr, now);
  }
  buffer
    ..writeln('<!-- mdformat on -->')
    ..writeln();
}

void _writeMarkdownPrRow(StringBuffer buffer, GhPr pr, DateTime now) {
  final repoUrl = pr.repoUrl.isNotEmpty
      ? pr.repoUrl
      : 'https://github.com/${pr.repository}';
  final queuePrefix = pr.isInMergeQueue ? '`[🔀 Merge Queue]` ' : '';
  final sanitizedTitle = pr.title
      .replaceAll('|', '/')
      .replaceAll('\n', ' ')
      .trim();

  final prLines = <String>[
    if (pr.context != null && pr.context!.trim().isNotEmpty) ...[
      pr.context!
          .trim()
          .replaceAll('|', '/')
          .replaceAll('\r\n', '\n')
          .replaceAll('\n', '<br>'),
      '',
    ],
    '[#${pr.number}](${pr.url}) $queuePrefix$sanitizedTitle',
    '[${pr.repository}]($repoUrl)',
  ];

  final branchLines = <String>[
    '`${pr.headRefName}`',
    _formatLocalMappingMarkdown(pr.localStatus),
  ];

  final areThreadsResolved =
      pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0;
  final isReady = _isReadyToMerge(pr);

  final statusLines = <String>[
    'Review: ${_formatReviewBadgeMarkdown(pr, areThreadsResolved)}',
    'CI: ${_formatCiBadgeMarkdown(pr.ciStatus)}',
    'Merge: ${_formatMergeableBadgeMarkdown(pr)}',
  ];

  final touched = formatTouchedMarkdown(pr.updatedAt, currentTime: now);
  final actionItem = _resolveActionItemMarkdown(
    pr,
    areThreadsResolved: areThreadsResolved,
    isReadyToMerge: isReady,
    now: now,
  );

  final prCell = prLines.join('<br>');
  final branchCell = branchLines.join('<br>');
  final statusCell = statusLines
      .map((line) => line.replaceAll(' ', '&nbsp;'))
      .join('<br>');

  buffer.writeln(
    '| $prCell | $branchCell | $statusCell | $touched | $actionItem |',
  );
}

String _resolveActionItemMarkdown(
  GhPr pr, {
  required bool areThreadsResolved,
  required bool isReadyToMerge,
  required DateTime now,
}) {
  if (pr.isRepoArchived) return '📦 Archived repo (read-only)';
  if (isReadyToMerge) return '🚀 **Ready to merge**';
  if (pr.isBlockedByProtection) {
    return '🧱 **Blocked by ruleset/branch protection**';
  }

  final reviewers = pr.targetReviewers;
  final hasReviewers = reviewers.isNotEmpty;
  final reviewersText = hasReviewers ? '@${reviewers.join(', @')}' : '';

  return switch ((
    pr.mergeable == MergeableState.conflicting,
    pr.ciStatus == CiStatus.failure,
    pr.reviewDecision,
    hasReviewers,
    areThreadsResolved,
    pr.unresolvedReviewThreads,
    pr.isDraft,
  )) {
    (true, _, _, _, _, _, true) => '⚠️ **Conflicting** (draft)',
    (true, _, _, _, _, _, false) => '⚠️ **Conflicting** (needs rebase)',
    (_, true, _, _, _, _, true) => '🔴 **CI Failing** (draft)',
    (_, true, _, _, _, _, false) => '🔴 **CI Failing** (needs fix)',
    (_, _, ReviewDecision.changesRequested, true, _, _, _) =>
      '🟡 **Re-review Requested** ($reviewersText)',
    (_, _, ReviewDecision.changesRequested, false, true, _, _) =>
      '🔄 **Re-review Needed** (threads resolved)',
    (_, _, ReviewDecision.changesRequested, false, false, > 0, _) =>
      '🔴 **Changes Requested** (${pr.unresolvedReviewThreads} open '
          'thread${pr.unresolvedReviewThreads > 1 ? 's' : ''})',
    (_, _, ReviewDecision.changesRequested, false, false, _, _) =>
      '🔴 **Changes Requested**',
    (_, _, ReviewDecision.reviewRequired || ReviewDecision.none, _, _, _, _) =>
      _resolveReviewRequiredActionMarkdown(
        pr,
        reviewersText: reviewersText,
        areThreadsResolved: areThreadsResolved,
        now: now,
      ),
    (_, _, _, _, _, _, true) => '⚪ **Work in progress**',
    _ => '⚪ **Active**',
  };
}

bool _isRecentPing(GhPr pr, DateTime now) {
  if (!pr.isAlreadyPinged) return false;
  final authorComment = pr.lastAuthorCommentAt;
  if (authorComment == null) return false;
  return now.difference(authorComment).inDays < 7;
}

String _resolveReviewRequiredActionMarkdown(
  GhPr pr, {
  required String reviewersText,
  required bool areThreadsResolved,
  required DateTime now,
}) {
  if (_isRecentPing(pr, now)) {
    final pingAge = formatTimeAgo(pr.lastAuthorCommentAt!, currentTime: now);
    if (reviewersText.isNotEmpty) {
      return '⏳ **Awaiting $reviewersText** (pinged $pingAge)';
    }
    return '⏳ **Awaiting Review** (pinged $pingAge)';
  }
  if (areThreadsResolved) {
    if (reviewersText.isNotEmpty) {
      return '🔔 **Ping Reviewer** ($reviewersText)';
    }
    return '🔔 **Ping Reviewer** (threads resolved)';
  }
  if (reviewersText.isNotEmpty) {
    return '⏳ **Awaiting $reviewersText**';
  }
  if (pr.isDraft) {
    return '⚪ **Work in progress**';
  }
  return '⏳ **Awaiting review**';
}

String _formatReviewBadgeMarkdown(GhPr pr, bool areThreadsResolved) {
  if (pr.reviewDecision == ReviewDecision.approved) return '🟢 Approved';
  if (pr.reviewDecision == ReviewDecision.changesRequested) {
    if (pr.targetReviewers.isNotEmpty) {
      return '🟡 Re-review Requested (@${pr.targetReviewers.join(', @')})';
    }
    if (areThreadsResolved) return '🔴 Changes Requested (Resolved)';
    if (pr.unresolvedReviewThreads > 0) {
      return '🔴 Changes Requested (${pr.unresolvedReviewThreads} open)';
    }
    return '🔴 Changes Requested';
  }
  if (pr.reviewDecision == ReviewDecision.reviewRequired) {
    if (pr.targetReviewers.isNotEmpty) {
      return '🟡 Review Required (@${pr.targetReviewers.join(', @')})';
    }
    return '🟡 Review Required';
  }
  return '⚪ None';
}

String _formatCiBadgeMarkdown(CiStatus ciStatus) => switch (ciStatus) {
  CiStatus.success => '🟢 Passing',
  CiStatus.treeBroken => '🟠 Tree Broken (PR Clean)',
  CiStatus.failure => '🔴 Failing',
  CiStatus.pending => '⏳ Pending',
  _ => '⚪ None',
};

String _formatMergeableBadgeMarkdown(GhPr pr) {
  if (pr.isBlockedMergeState) {
    return '🧱 Blocked';
  }

  final label = switch (pr.mergeable) {
    MergeableState.mergeable => '✅ Yes',
    MergeableState.conflicting => '⚠️ Conflicting',
    _ => pr.isInMergeQueue ? '✅ Yes' : '⚪ Unknown',
  };
  return pr.isInMergeQueue ? '$label (🔀 Queue)' : label;
}

String _formatLocalMappingMarkdown(LocalBranchStatus? loc) {
  if (loc == null) return 'Local: ⚪ Not checked out';
  final dirName = p.basename(loc.repoPath);
  return 'Local: ${loc.displayStatus} ([$dirName](file://${loc.repoPath}))';
}

/// Renders machine-readable JSON output.
String renderJsonOutput(List<GhPr> prs, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final categorized = categorizePullRequests(prs);

  Map<String, dynamic> prToJson(GhPr pr) => {
    'number': pr.number,
    'title': pr.title,
    'url': pr.url,
    'author': pr.author,
    'repository': pr.repository,
    'repoUrl': pr.repoUrl,
    'isRepoArchived': pr.isRepoArchived,
    'isDraft': pr.isDraft,
    'state': pr.state,
    'reviewDecision': pr.reviewDecision,
    'requestedReviewers': pr.requestedReviewers,
    'activeReviewers': pr.activeReviewers,
    'targetReviewers': pr.targetReviewers,
    'isAlreadyPinged': pr.isAlreadyPinged,
    'lastAuthorCommentAt': pr.lastAuthorCommentAt?.toIso8601String(),
    'lastReviewerActivityAt': pr.lastReviewerActivityAt?.toIso8601String(),
    'totalReviewThreads': pr.totalReviewThreads,
    'unresolvedReviewThreads': pr.unresolvedReviewThreads,
    'areAllReviewThreadsResolved':
        pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0,
    'ciStatus': pr.ciStatus,
    'mergeable': pr.mergeable,
    'mergeStateStatus': pr.mergeStateStatus,
    'isInMergeQueue': pr.isInMergeQueue,
    'headRefName': pr.headRefName,
    'headRefOid': pr.headRefOid,
    'baseRefName': pr.baseRefName,
    'updatedAt': pr.updatedAt.toIso8601String(),
    'touched': formatTimeAgo(pr.updatedAt, currentTime: now),
    'context': pr.context,
    'local': pr.localStatus == null
        ? null
        : {
            'path': pr.localStatus!.repoPath,
            'branch': pr.localStatus!.branchName,
            'shortSha': pr.localStatus!.shortSha,
            'isDirty': pr.localStatus!.isDirty,
            'isHeadMatching': pr.localStatus!.isHeadMatching,
            'isWorktree': pr.localStatus!.isWorktree,
            'status': pr.localStatus!.displayStatus,
          },
  };

  final data = {
    'summary': {
      'total': prs.length,
      'readyToMerge': categorized.readyToMerge.length,
      'actionNeeded': categorized.actionNeeded.length,
      'inReview': categorized.inReview.length,
      'drafts': categorized.drafts.length,
      'archived': categorized.archived.length,
    },
    'readyToMerge': categorized.readyToMerge.map(prToJson).toList(),
    'actionNeeded': categorized.actionNeeded.map(prToJson).toList(),
    'inReview': categorized.inReview.map(prToJson).toList(),
    'drafts': categorized.drafts.map(prToJson).toList(),
    'archived': categorized.archived.map(prToJson).toList(),
  };

  return const JsonEncoder.withIndent('  ').convert(data);
}
