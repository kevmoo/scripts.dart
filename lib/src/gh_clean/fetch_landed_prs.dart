import '../local_repo_scanner.dart';
import '../process_utils.dart';
import '../shared/gh_pr_ref.dart';
import '../shared/graphql_utils.dart';
import 'models.dart';

/// Builds the GraphQL search query for merged PRs.
String buildLandedSearchQuery({
  required String user,
  String? repo,
  int? lastNDays,
  DateTime? now,
}) {
  if (lastNDays != null && lastNDays <= 0) {
    throw ArgumentError.value(
      lastNDays,
      'lastNDays',
      'Must be a positive integer.',
    );
  }

  final buffer = StringBuffer('is:pr is:merged');
  if (user.isNotEmpty) buffer.write(' author:$user');
  if (repo != null && repo.isNotEmpty) buffer.write(' repo:$repo');

  if (lastNDays != null) {
    final reference = now ?? DateTime.now();
    final cutoff = reference.subtract(Duration(days: lastNDays));
    final y = cutoff.year.toString().padLeft(4, '0');
    final m = cutoff.month.toString().padLeft(2, '0');
    final d = cutoff.day.toString().padLeft(2, '0');
    buffer.write(' merged:>=$y-$m-$d');
  }

  buffer.write(' sort:updated-desc');
  return buffer.toString();
}

/// Fetches merged pull requests via GitHub CLI (`gh api graphql`).
Future<List<LandedPr>> fetchLandedPrs({
  required String user,
  String? repo,
  int? lastNDays = 7,
  int limit = 50,
  bool includeOwned = true,
  SyncProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final queryStr = buildLandedSearchQuery(
    user: user,
    repo: repo,
    lastNDays: lastNDays,
  );

  const gqlQuery = r'''
query($q: String!, $limit: Int!, $cursor: String) {
  search(query: $q, type: ISSUE, first: $limit, after: $cursor) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on PullRequest {
        number
        title
        url
        state
        merged
        mergedAt
        closedAt
        headRefName
        headRefOid
        headRef {
          name
        }
        headRepository {
          nameWithOwner
          viewerPermission
        }
        baseRefName
        repository {
          nameWithOwner
          url
          isArchived
        }
        mergeCommit {
          oid
        }
      }
    }
  }
}
''';

  final nodes = paginateGraphQLSearchSync(
    graphqlQuery: gqlQuery,
    searchQuery: queryStr,
    limit: limit,
    runner: runner,
    exceptionBuilder: (message, {exitCode = 1}) =>
        GhCleanException(message, exitCode: exitCode),
  );

  return [
    for (final node in nodes)
      if (parseLandedPrNode(node) case final parsed?)
        if (!isDartSdkRepositoryName(parsed.repository) &&
            (includeOwned ||
                user.isEmpty ||
                user == '@me' ||
                !parsed.repository.toLowerCase().startsWith(
                  '${user.toLowerCase()}/',
                )))
          parsed,
  ];
}

/// Parses a landed PR node from GraphQL.
LandedPr? parseLandedPrNode(Map<String, dynamic> node) {
  final core = GhPrRef.parseCoreFields(node, defaultBaseRefName: 'main');
  if (core == null) return null;

  final mergedAtStr = node['mergedAt'] as String?;
  final mergedAt = mergedAtStr != null ? DateTime.tryParse(mergedAtStr) : null;

  final closedAtStr = node['closedAt'] as String?;
  final closedAt = closedAtStr != null ? DateTime.tryParse(closedAtStr) : null;

  final mergeCommit = node['mergeCommit'] as Map<String, dynamic>?;
  final mergeSha = mergeCommit?['oid'] as String?;

  final headRefExists = node['headRef'] != null;
  final headRepoMap = node['headRepository'] as Map<String, dynamic>?;
  final headRepository = headRepoMap?['nameWithOwner'] as String?;
  final headRepoPermission = headRepoMap?['viewerPermission'] as String?;

  return LandedPr(
    number: core.number,
    title: core.title,
    url: core.url,
    repository: core.repository,
    repoUrl: core.repoUrl,
    headRefName: core.headRefName,
    headRefOid: core.headRefOid,
    baseRefName: core.baseRefName,
    mergeSha: mergeSha,
    mergedAt: mergedAt,
    closedAt: closedAt,
    headRefExists: headRefExists,
    headRepository: headRepository,
    headRepoPermission: headRepoPermission,
  );
}
