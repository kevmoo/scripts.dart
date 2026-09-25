import 'dart:io';

import '../gh_view.dart';
import '../process_utils.dart';
import '../shared/graphql_utils.dart';

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
        reviews(last: 25) {
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
              committedDate
              pushedDate
              statusCheckRollup {
                state
                contexts(first: 50) {
                  nodes {
                    __typename
                    ... on StatusContext {
                      context
                      state
                      description
                    }
                    ... on CheckRun {
                      name
                      conclusion
                      status
                      title
                      summary
                      text
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
    maxPageSize: 15,
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
  final approvedReviewers = _extractApprovedReviewers(
    node['reviews'] as Map<String, dynamic>?,
    prAuthor,
  );
  final reviewerActivity = _extractReviewerActivity(
    node['reviews'] as Map<String, dynamic>?,
    node['comments'] as Map<String, dynamic>?,
    prAuthor,
    excludedFromUnrequested: {...requested.allReviewers, ...approvedReviewers},
  );
  final authorComment = _extractAuthorComment(
    node['comments'] as Map<String, dynamic>?,
    prAuthor,
  );
  final lastAuthorReviewAt = _extractLatestAuthorReviewAt(
    node['reviews'] as Map<String, dynamic>?,
    prAuthor,
  );
  final lastCommitAt = _extractLastCommitDateTime(
    node['commits'] as Map<String, dynamic>?,
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
  final ciStatus = extractCiStatus(
    core.repository,
    node['commits'] as Map<String, dynamic>?,
  );
  final ciDetail = extractCiDetail(node['commits'] as Map<String, dynamic>?);

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
    reviewAuthors: reviewerActivity.reviewAuthors,
    approvedReviewers: approvedReviewers,
    totalReviewThreads: threads.total,
    unresolvedReviewThreads: threads.unresolved,
    lastAuthorCommentAt: lastAuthorCommentAt,
    lastAuthorReviewAt: lastAuthorReviewAt,
    lastCommitAt: lastCommitAt,
    lastReviewerActivityAt: lastReviewerActivityAt,
    lastUnrequestedReviewAt: reviewerActivity.lastUnrequestedReviewAt,
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
    ciDetail: ciDetail,
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

DateTime? _laterDateTime(DateTime? current, DateTime? candidate) {
  if (candidate == null) return current;
  if (current == null || candidate.isAfter(current)) return candidate;
  return current;
}

({Set<String> logins, DateTime? latestAt, DateTime? latestUnexcludedAt})
_collectNodeParticipants(
  List<dynamic>? nodes,
  String dateKey,
  String prAuthor, {
  Set<String> excludedLogins = const {},
}) {
  final logins = <String>{};
  DateTime? latestAt;
  DateTime? latestUnexcludedAt;
  for (final item in (nodes ?? const []).whereType<Map<String, dynamic>>()) {
    final login = _extractNodeLogin(item);
    if (!_isHumanReviewer(login, prAuthor)) continue;
    logins.add(login!);
    final dt = _extractNodeDateTime(item, dateKey);
    latestAt = _laterDateTime(latestAt, dt);
    if (!excludedLogins.contains(login)) {
      latestUnexcludedAt = _laterDateTime(latestUnexcludedAt, dt);
    }
  }
  return (
    logins: logins,
    latestAt: latestAt,
    latestUnexcludedAt: latestUnexcludedAt,
  );
}

({
  DateTime? lastReviewerActivityAt,
  DateTime? lastUnrequestedReviewAt,
  List<String> humanParticipants,
  List<String> reviewAuthors,
})
_extractReviewerActivity(
  Map<String, dynamic>? reviewsObj,
  Map<String, dynamic>? commentsObj,
  String prAuthor, {
  Set<String> excludedFromUnrequested = const {},
}) {
  final reviewStats = _collectNodeParticipants(
    reviewsObj?['nodes'] as List<dynamic>?,
    'submittedAt',
    prAuthor,
    excludedLogins: excludedFromUnrequested,
  );
  final commentStats = _collectNodeParticipants(
    commentsObj?['nodes'] as List<dynamic>?,
    'createdAt',
    prAuthor,
  );
  return (
    lastReviewerActivityAt: _laterDateTime(
      reviewStats.latestAt,
      commentStats.latestAt,
    ),
    lastUnrequestedReviewAt: reviewStats.latestUnexcludedAt,
    humanParticipants: {...reviewStats.logins, ...commentStats.logins}.toList(),
    reviewAuthors: reviewStats.logins.toList(),
  );
}

({DateTime? lastAuthorCommentAt, List<String> mentionedUsers})
_extractAuthorComment(Map<String, dynamic>? commentsObj, String prAuthor) {
  if (prAuthor.isEmpty) {
    return (lastAuthorCommentAt: null, mentionedUsers: const []);
  }
  DateTime? lastCommentAt;
  var latestBody = '';
  final commentNodes = commentsObj?['nodes'] as List<dynamic>? ?? const [];
  for (final item in commentNodes.whereType<Map<String, dynamic>>()) {
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

DateTime? _extractLatestAuthorReviewAt(
  Map<String, dynamic>? reviewsObj,
  String prAuthor,
) {
  if (prAuthor.isEmpty) return null;
  DateTime? latest;
  final reviewNodes = reviewsObj?['nodes'] as List<dynamic>? ?? const [];
  for (final item in reviewNodes.whereType<Map<String, dynamic>>()) {
    if (_extractNodeLogin(item) != prAuthor) continue;
    final dt = _extractNodeDateTime(item, 'submittedAt');
    if (dt != null && (latest == null || dt.isAfter(latest))) {
      latest = dt;
    }
  }
  return latest;
}

DateTime? _extractLastCommitDateTime(Map<String, dynamic>? commitsObj) {
  final nodes = commitsObj?['nodes'] as List<dynamic>? ?? const [];
  if (nodes.isEmpty) return null;
  final lastNode = nodes.last;
  if (lastNode is! Map<String, dynamic>) return null;
  final commit = lastNode['commit'] as Map<String, dynamic>?;
  if (commit == null) return null;
  final pushed = _extractNodeDateTime(commit, 'pushedDate');
  final committed = _extractNodeDateTime(commit, 'committedDate');
  if (pushed == null) return committed;
  if (committed == null) return pushed;
  return pushed.isAfter(committed) ? pushed : committed;
}

List<String> _extractMentionedUsers(String body, String prAuthor) {
  if (body.isEmpty) return const [];
  final mentioned = <String>{};
  for (final match in _mentionRegex.allMatches(body)) {
    final user = match.group(1);
    if (_isHumanReviewer(user, prAuthor)) {
      mentioned.add(user!);
    }
  }
  return mentioned.toList();
}

final _mentionRegex = RegExp('@([a-zA-Z0-9-]+)');

bool _shouldUpdateReviewState(String? previousState, String newState) =>
    newState.isNotEmpty &&
    (newState != 'COMMENTED' || previousState != 'APPROVED');

List<String> _extractApprovedReviewers(
  Map<String, dynamic>? reviewsObj,
  String prAuthor,
) {
  final latestStateByReviewer = <String, String>{};
  final nodes = reviewsObj?['nodes'] as List<dynamic>? ?? const [];
  for (final item in nodes.whereType<Map<String, dynamic>>()) {
    final login = _extractNodeLogin(item);
    if (!_isHumanReviewer(login, prAuthor)) continue;
    final state = item['state'] as String? ?? '';
    if (_shouldUpdateReviewState(latestStateByReviewer[login!], state)) {
      latestStateByReviewer[login] = state;
    }
  }
  return latestStateByReviewer.entries
      .where((e) => e.value == 'APPROVED')
      .map((e) => e.key)
      .toList();
}

List<String> _resolveActiveReviewers({
  required List<String> humanRequested,
  required List<String> humanParticipants,
  required List<String> mentionedUsers,
  required bool isAlreadyPinged,
}) {
  if (isAlreadyPinged && mentionedUsers.isNotEmpty) {
    return {
      ...mentionedUsers,
      ...humanRequested,
      ...humanParticipants,
    }.toList();
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
