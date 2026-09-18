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
  final ciStatus = extractCiStatus(
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
  for (final match in _mentionRegex.allMatches(body)) {
    final user = match.group(1);
    if (_isHumanReviewer(user, prAuthor)) {
      mentioned.add(user!);
    }
  }
  return mentioned.toList();
}

final _mentionRegex = RegExp('@([a-zA-Z0-9-]+)');

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
