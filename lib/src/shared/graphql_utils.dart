import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../process_utils.dart';

/// Known automated bot logins on GitHub.
const knownBotLogins = <String>{
  'cla-bot',
  'codecov',
  'codecov-commenter',
  'coveralls',
  'dependabot',
  'flutter-dashboard',
  'fluttergithubbot',
  'gemini-code-assist',
  'github-actions',
  'google-cla',
};

/// Returns true if [login] represents an automated GitHub bot account.
bool isBotLogin(String login) {
  final lower = login.toLowerCase();
  return lower.endsWith('[bot]') ||
      lower.endsWith('-bot') ||
      knownBotLogins.contains(lower);
}

/// Helper to extract search node lists from GitHub GraphQL API responses.
List<dynamic> extractGraphQLSearchNodes(Map<String, dynamic> decoded) {
  final data = decoded['data'] as Map<String, dynamic>?;
  final search = data?['search'] as Map<String, dynamic>?;
  return search?['nodes'] as List<dynamic>? ?? [];
}

/// Extracts pagination info (`hasNextPage` and `endCursor`) from a decoded
/// GitHub GraphQL `search` response.
({bool hasNextPage, String? endCursor}) extractGraphQLSearchPageInfo(
  Map<String, dynamic> decoded,
) {
  final data = decoded['data'] as Map<String, dynamic>?;
  final search = data?['search'] as Map<String, dynamic>?;
  final pageInfo = search?['pageInfo'] as Map<String, dynamic>?;
  final hasNextPage = pageInfo?['hasNextPage'] as bool? ?? false;
  final endCursor = pageInfo?['endCursor'] as String?;
  return (hasNextPage: hasNextPage, endCursor: endCursor);
}

/// Executes a cursor-paginated GitHub GraphQL `search` query asynchronously
/// in chunks of at most [maxPageSize] up to [limit] total items.
///
/// The [graphqlQuery] must accept variables `$q: String!`, `$limit: Int!`,
/// and `$cursor: String`, and include `pageInfo { hasNextPage endCursor }`
/// inside `search(...)`.
Future<List<Map<String, dynamic>>> paginateGraphQLSearch({
  required String graphqlQuery,
  required String searchQuery,
  required int limit,
  required ProcessRunner runner,
  required Exception Function(String message, {int exitCode}) exceptionBuilder,
  int maxPageSize = 25,
}) async {
  final nodes = <Map<String, dynamic>>[];
  String? cursor;

  while (nodes.length < limit) {
    final pageSize = math.min(maxPageSize, limit - nodes.length);
    final args = _buildGraphQLArgs(
      graphqlQuery: graphqlQuery,
      searchQuery: searchQuery,
      pageSize: pageSize,
      cursor: cursor,
    );

    final result = await runner('gh', args);
    final decoded = _decodeAndValidateGraphQL(
      result,
      exceptionBuilder: exceptionBuilder,
    );
    final pageNodes = extractGraphQLSearchNodes(decoded)
        .whereType<Map<String, dynamic>>()
        .toList();
    nodes.addAll(pageNodes);

    final pageInfo = extractGraphQLSearchPageInfo(decoded);
    if (!pageInfo.hasNextPage ||
        pageInfo.endCursor == null ||
        pageNodes.isEmpty) {
      break;
    }
    cursor = pageInfo.endCursor;
  }

  return nodes;
}

/// Synchronous variant of [paginateGraphQLSearch] for callers using
/// [SyncProcessRunner] (e.g., `gh-clean`).
List<Map<String, dynamic>> paginateGraphQLSearchSync({
  required String graphqlQuery,
  required String searchQuery,
  required int limit,
  required SyncProcessRunner runner,
  required Exception Function(String message, {int exitCode}) exceptionBuilder,
  int maxPageSize = 50,
}) {
  final nodes = <Map<String, dynamic>>[];
  String? cursor;

  while (nodes.length < limit) {
    final pageSize = math.min(maxPageSize, limit - nodes.length);
    final args = _buildGraphQLArgs(
      graphqlQuery: graphqlQuery,
      searchQuery: searchQuery,
      pageSize: pageSize,
      cursor: cursor,
    );

    final result = runner('gh', args);
    final decoded = _decodeAndValidateGraphQL(
      result,
      exceptionBuilder: exceptionBuilder,
    );
    final pageNodes = extractGraphQLSearchNodes(decoded)
        .whereType<Map<String, dynamic>>()
        .toList();
    nodes.addAll(pageNodes);

    final pageInfo = extractGraphQLSearchPageInfo(decoded);
    if (!pageInfo.hasNextPage ||
        pageInfo.endCursor == null ||
        pageNodes.isEmpty) {
      break;
    }
    cursor = pageInfo.endCursor;
  }

  return nodes;
}

List<String> _buildGraphQLArgs({
  required String graphqlQuery,
  required String searchQuery,
  required int pageSize,
  String? cursor,
}) => <String>[
  'api',
  'graphql',
  '-f',
  'query=$graphqlQuery',
  '-F',
  'q=$searchQuery',
  '-F',
  'limit=$pageSize',
  if (cursor != null) ...['-F', 'cursor=$cursor'],
];

Map<String, dynamic> _decodeAndValidateGraphQL(
  ProcessResult result, {
  required Exception Function(String message, {int exitCode}) exceptionBuilder,
}) {
  if (result.exitCode != 0) {
    throw exceptionBuilder(
      'Failed to fetch via GitHub CLI (gh).\n'
      'Make sure `gh` is installed and authenticated (`gh auth login`).\n'
      'Error: ${result.stderr}',
      exitCode: result.exitCode,
    );
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(result.stdout as String);
  } catch (e) {
    throw exceptionBuilder(
      'Failed to parse GitHub GraphQL response: $e\nOutput:\n${result.stdout}',
      exitCode: result.exitCode != 0 ? result.exitCode : 70,
    );
  }

  if (decoded is! Map<String, dynamic>) {
    throw exceptionBuilder('Invalid GraphQL response structure.');
  }

  if (decoded.containsKey('errors')) {
    final errors = decoded['errors'] as List<dynamic>? ?? [];
    final errorMessages = errors
        .whereType<Map<String, dynamic>>()
        .map((e) => e['message'] as String? ?? 'Unknown GraphQL error')
        .join('\n');
    throw exceptionBuilder('GraphQL query returned errors:\n$errorMessages');
  }

  return decoded;
}
