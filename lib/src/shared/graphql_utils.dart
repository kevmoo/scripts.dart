/// Helper to extract search node lists from GitHub GraphQL API responses.
List<dynamic> extractGraphQLSearchNodes(Map<String, dynamic> decoded) {
  final data = decoded['data'] as Map<String, dynamic>?;
  final search = data?['search'] as Map<String, dynamic>?;
  return search?['nodes'] as List<dynamic>? ?? [];
}
