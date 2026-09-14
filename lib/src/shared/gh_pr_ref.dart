/// Base representation of a GitHub Pull Request shared between open (`gh-view`)
/// and landed (`gh-clean`) pull request models.
abstract class GhPrRef {
  final int number;
  final String title;
  final String url;
  final String repository;
  final String repoUrl;
  final String headRefName;
  final String headRefOid;
  final String baseRefName;

  const new({
    required this.number,
    required this.title,
    required this.url,
    required this.repository,
    required this.repoUrl,
    required this.headRefName,
    required this.headRefOid,
    required this.baseRefName,
  });

  /// Short repository name without the owner prefix (e.g. `melos` from
  /// `invertase/melos`).
  String get repoShortName => repository.split('/').last;

  /// Markdown link to the pull request (`[#$number]($url)`).
  String get markdownLink => '[#$number]($url)';

  /// Markdown link to the repository (`[$repository]($repoUrl)`).
  String get markdownRepoLink =>
      repoUrl.isNotEmpty ? '[$repository]($repoUrl)' : repository;

  /// Parses the core identity fields shared by all GitHub PR GraphQL nodes.
  ///
  /// Returns `null` if any required identity field (`number`, `title`, `url`,
  /// or `repository.nameWithOwner`) is missing.
  static ({
    int number,
    String title,
    String url,
    String repository,
    String repoUrl,
    String headRefName,
    String headRefOid,
    String baseRefName,
  })?
  parseCoreFields(Map<String, dynamic> node, {String defaultBaseRefName = ''}) {
    final number = node['number'] as int?;
    final title = node['title'] as String?;
    final url = node['url'] as String?;
    final repoMap = node['repository'] as Map<String, dynamic>?;
    final repository = repoMap?['nameWithOwner'] as String? ?? '';

    if (number == null || title == null || url == null || repository.isEmpty) {
      return null;
    }

    return (
      number: number,
      title: title,
      url: url,
      repository: repository,
      repoUrl: repoMap?['url'] as String? ?? '',
      headRefName: node['headRefName'] as String? ?? '',
      headRefOid: node['headRefOid'] as String? ?? '',
      baseRefName: node['baseRefName'] as String? ?? defaultBaseRefName,
    );
  }
}
