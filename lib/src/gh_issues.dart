import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'process_utils.dart';
import 'shared/gh_args.dart';

import 'package:io/ansi.dart';
import 'package:io/io.dart';
import 'package:pool/pool.dart';

import 'gh_view.dart' show formatTouchedMarkdown, formatTouchedTerminal;

/// Exception thrown by `gh-issues` operations.
class GhIssuesException implements Exception {
  final String message;
  final int exitCode;

  new(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}

/// Representation of a linked GitHub Pull Request.
typedef LinkedPr = ({int number, String url, String state, String repository});

/// Representation of an open GitHub Issue.
typedef GhIssue = ({
  int number,
  String title,
  String url,
  String repository,
  String repoUrl,
  DateTime createdAt,
  DateTime updatedAt,
  List<String> labels,
  int commentsCount,
  List<LinkedPr> linkedPrs,
});

/// Argument configuration for `gh-issues`.
class GhIssuesOptions {
  final String user;
  final String? repo;
  final int limit;
  final int? lastNDays;
  final int? createdDays;
  final bool checkLinkedPrs;
  final bool json;
  final bool markdown;

  const new({
    this.user = '@me',
    this.repo,
    this.limit = 50,
    this.lastNDays,
    this.createdDays = 365,
    this.checkLinkedPrs = true,
    this.json = false,
    this.markdown = false,
  });

  static ArgParser createArgParser() {
    final parser = ArgParser();
    addCommonGhArgs(
      parser,
      itemType: 'issues',
      userHelp: 'The GitHub user assigned to the issues.',
    );
    parser
      ..addOption(
        'created-days',
        abbr: 'c',
        defaultsTo: '365',
        help:
            'Filter issues created in the last N days (positive integer, 0 for '
            'no limit).',
      )
      ..addFlag(
        'linked-prs',
        defaultsTo: true,
        help: 'Cross-reference linked Pull Requests.',
      );
    return parser;
  }
}

/// Constructs the GitHub search query for assigned issues.
String buildSearchQuery({
  required String user,
  String? repo,
  int? lastNDays,
  int? createdDays,
  DateTime? now,
}) {
  final currentTime = now ?? DateTime.now();
  final buffer = StringBuffer('is:issue is:open');
  if (user.isNotEmpty) {
    buffer.write(' assignee:$user');
  }
  if (repo != null && repo.isNotEmpty) {
    buffer.write(' repo:$repo');
  }
  if (createdDays != null && createdDays > 0) {
    final cutoff = currentTime.subtract(Duration(days: createdDays));
    final dateStr = cutoff.toIso8601String().substring(0, 10);
    buffer.write(' created:>=$dateStr');
  }
  if (lastNDays != null && lastNDays > 0) {
    final cutoff = currentTime.subtract(Duration(days: lastNDays));
    final dateStr = cutoff.toIso8601String().substring(0, 10);
    buffer.write(' updated:>=$dateStr');
  }
  buffer.write(' sort:updated-desc');
  return buffer.toString();
}

/// Parses a single linked PR object from GraphQL.
LinkedPr? parseLinkedPr(Map<String, dynamic> prObj) {
  final number = prObj['number'] as int?;
  final url = prObj['url'] as String?;
  final state = prObj['state'] as String? ?? 'OPEN';
  final repoMap = prObj['repository'] as Map<String, dynamic>?;
  var repository = repoMap?['nameWithOwner'] as String? ?? '';

  if (number == null || url == null) return null;

  if (repository.isEmpty) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.pathSegments.length >= 2) {
      repository = '${uri.pathSegments[0]}/${uri.pathSegments[1]}';
    }
  }

  return (number: number, url: url, state: state, repository: repository);
}

DateTime _parseDateTime(String? dateStr) => dateStr != null
    ? DateTime.tryParse(dateStr) ?? DateTime.now()
    : DateTime.now();

List<String> _extractLabelsFromNode(Map<String, dynamic>? labelsObj) {
  final labelNodes = labelsObj?['nodes'] as List<dynamic>? ?? const [];
  final labels = <String>[];
  for (final l in labelNodes) {
    if (l is Map<String, dynamic>) {
      final name = l['name'] as String?;
      if (name != null && name.isNotEmpty) {
        labels.add(name);
      }
    }
  }
  return labels;
}

List<LinkedPr> _extractClosedByPrs(Map<String, dynamic>? closedByPrsObj) {
  final closedByNodes = closedByPrsObj?['nodes'] as List<dynamic>? ?? const [];
  final prsMap = <String, LinkedPr>{};
  for (final n in closedByNodes) {
    if (n is Map<String, dynamic>) {
      final pr = parseLinkedPr(n);
      if (pr != null) {
        prsMap[pr.url] = pr;
      }
    }
  }
  return _sortPrs(prsMap.values);
}

List<LinkedPr> _sortPrs(Iterable<LinkedPr> prs) => prs.toList()
  ..sort((a, b) {
    final repoComp = a.repository.compareTo(b.repository);
    if (repoComp != 0) return repoComp;
    return a.number.compareTo(b.number);
  });

/// Parses a single issue node from the search query.
GhIssue? parseIssueNode(Map<String, dynamic> node) {
  final number = node['number'] as int?;
  final title = node['title'] as String?;
  final url = node['url'] as String?;
  final repoMap = node['repository'] as Map<String, dynamic>?;
  final repository = repoMap?['nameWithOwner'] as String? ?? '';
  final repoUrl = repoMap?['url'] as String? ?? '';

  if (number == null || title == null || url == null || repository.isEmpty) {
    return null;
  }

  final commentsObj = node['comments'] as Map<String, dynamic>?;
  final commentsCount = commentsObj?['totalCount'] as int? ?? 0;

  return (
    number: number,
    title: title,
    url: url,
    repository: repository,
    repoUrl: repoUrl,
    createdAt: _parseDateTime(node['createdAt'] as String?),
    updatedAt: _parseDateTime(node['updatedAt'] as String?),
    labels: _extractLabelsFromNode(node['labels'] as Map<String, dynamic>?),
    commentsCount: commentsCount,
    linkedPrs: _extractClosedByPrs(
      node['closedByPullRequestsReferences'] as Map<String, dynamic>?,
    ),
  );
}

/// Fetches timeline PRs (cross-referenced / connected) for a specific issue.
Future<List<LinkedPr>> fetchTimelinePrsForIssue({
  required GhIssue issue,
  ProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? Process.run;
  final parts = issue.repository.split('/');
  if (parts.length != 2) return const [];
  final owner = parts[0];
  final name = parts[1];

  const query = r'''
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      timelineItems(itemTypes: [CONNECTED_EVENT, CROSS_REFERENCED_EVENT], last: 10) {
        nodes {
          ... on ConnectedEvent {
            subject {
              ... on PullRequest {
                number
                url
                state
                repository {
                  nameWithOwner
                }
              }
            }
          }
          ... on CrossReferencedEvent {
            source {
              ... on PullRequest {
                number
                url
                state
                repository {
                  nameWithOwner
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

  final result = await runner('gh', [
    'api',
    'graphql',
    '-f',
    'query=$query',
    '-F',
    'owner=$owner',
    '-F',
    'name=$name',
    '-F',
    'number=${issue.number}',
  ]);

  if (result.exitCode != 0) return const [];

  try {
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map<String, dynamic>) return const [];
    final data = decoded['data'] as Map<String, dynamic>?;
    final repoMap = data?['repository'] as Map<String, dynamic>?;
    final issueMap = repoMap?['issue'] as Map<String, dynamic>?;
    final timeline = issueMap?['timelineItems'] as Map<String, dynamic>?;
    final nodes = timeline?['nodes'] as List<dynamic>? ?? [];

    final prs = <String, LinkedPr>{};
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) continue;
      final prObj =
          (node['subject'] as Map<String, dynamic>?) ??
          (node['source'] as Map<String, dynamic>?);
      if (prObj == null) continue;
      final pr = parseLinkedPr(prObj);
      if (pr != null) {
        prs[pr.url] = pr;
      }
    }
    return prs.values.toList();
  } catch (_) {
    return const [];
  }
}

const _graphqlSearchQuery = r'''
query($q: String!, $limit: Int!) {
  search(query: $q, type: ISSUE, first: $limit) {
    issueCount
    nodes {
      ... on Issue {
        number
        title
        url
        repository {
          nameWithOwner
          url
        }
        updatedAt
        createdAt
        comments {
          totalCount
        }
        labels(first: 10) {
          nodes {
            name
          }
        }
        closedByPullRequestsReferences(first: 10) {
          nodes {
            number
            url
            state
            repository {
              nameWithOwner
            }
          }
        }
      }
    }
  }
}
''';

Map<String, dynamic> _parseGraphQLResponse(ProcessResult result) {
  if (result.exitCode != 0) {
    throw GhIssuesException(
      'Failed to fetch issues via GitHub CLI (gh).\n'
      'Make sure `gh` is installed and authenticated (`gh auth login`).\n'
      'Error: ${result.stderr}',
      exitCode: ExitCode.software.code,
    );
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(result.stdout as String);
  } catch (e) {
    throw GhIssuesException(
      'Failed to parse GitHub GraphQL response: $e\nOutput:\n${result.stdout}',
      exitCode: ExitCode.software.code,
    );
  }

  if (decoded is! Map<String, dynamic>) {
    throw GhIssuesException('Invalid GraphQL response structure.');
  }

  return decoded;
}

List<GhIssue> _extractIssuesFromSearchData(Map<String, dynamic> data) {
  final search = data['search'] as Map<String, dynamic>?;
  final nodes = search?['nodes'] as List<dynamic>? ?? const [];
  return nodes
      .whereType<Map<String, dynamic>>()
      .map(parseIssueNode)
      .whereType<GhIssue>()
      .toList();
}

Future<GhIssue> _enrichSingleIssue(
  GhIssue issue, {
  required ProcessRunner runner,
}) async {
  try {
    final additionalPrs = await fetchTimelinePrsForIssue(
      issue: issue,
      processRunner: runner,
    );
    if (additionalPrs.isEmpty) return issue;

    final prMap = <String, LinkedPr>{
      for (final pr in issue.linkedPrs) pr.url: pr,
      for (final pr in additionalPrs) pr.url: pr,
    };

    return (
      number: issue.number,
      title: issue.title,
      url: issue.url,
      repository: issue.repository,
      repoUrl: issue.repoUrl,
      createdAt: issue.createdAt,
      updatedAt: issue.updatedAt,
      labels: issue.labels,
      commentsCount: issue.commentsCount,
      linkedPrs: _sortPrs(prMap.values),
    );
  } catch (_) {
    return issue;
  }
}

Future<List<GhIssue>> _enrichWithTimelinePrs(
  List<GhIssue> issues, {
  required ProcessRunner runner,
}) {
  final pool = Pool(8);
  return Future.wait(
    issues.map(
      (issue) =>
          pool.withResource(() => _enrichSingleIssue(issue, runner: runner)),
    ),
  );
}

/// Fetches assigned issues via GitHub GraphQL.
Future<List<GhIssue>> fetchAssignedIssues({
  required String user,
  String? repo,
  int limit = 50,
  int? lastNDays,
  int? createdDays,
  bool checkLinkedPrs = true,
  ProcessRunner? processRunner,
  DateTime? now,
}) async {
  final runner = processRunner ?? Process.run;
  final searchQuery = buildSearchQuery(
    user: user,
    repo: repo,
    lastNDays: lastNDays,
    createdDays: createdDays,
    now: now,
  );

  final result = await runner('gh', [
    'api',
    'graphql',
    '-f',
    'query=$_graphqlSearchQuery',
    '-F',
    'q=$searchQuery',
    '-F',
    'limit=$limit',
  ]);

  final decoded = _parseGraphQLResponse(result);
  final data = decoded['data'] as Map<String, dynamic>? ?? const {};
  final parsedIssues = _extractIssuesFromSearchData(data);

  if (!checkLinkedPrs || parsedIssues.isEmpty) {
    return parsedIssues;
  }

  return _enrichWithTimelinePrs(parsedIssues, runner: runner);
}

String _formatLabels(List<String> labels) {
  if (labels.isEmpty) return '—';
  final firstThree = labels.take(3).join(', ');
  final remaining = labels.length > 3 ? ' (+${labels.length - 3})' : '';
  return '`$firstThree$remaining`';
}

String _formatLinkedPrsMarkdown(GhIssue issue) {
  if (issue.linkedPrs.isEmpty) return '—';
  final links = <String>[];
  for (final pr in issue.linkedPrs) {
    final emoji = switch (pr.state) {
      'OPEN' => '🟢',
      'MERGED' => '🟣',
      'CLOSED' => '🔴',
      _ => '⚪',
    };
    final label = pr.repository == issue.repository
        ? '#${pr.number}'
        : '${pr.repository}#${pr.number}';
    links.add('$emoji [$label](${pr.url})');
  }
  return links.join('<br>');
}

/// Renders GitHub Flavored Markdown output.
String renderMarkdownReport(
  List<GhIssue> issues, {
  required GhIssuesOptions options,
  DateTime? currentTime,
}) {
  final now = currentTime ?? DateTime.now();
  final buffer = StringBuffer();

  final withPrsCount = issues.where((i) => i.linkedPrs.isNotEmpty).length;
  final recentCutoff = now.subtract(const Duration(days: 7));
  final recentCount = issues
      .where((i) => !i.updatedAt.isBefore(recentCutoff))
      .length;

  buffer
    ..writeln('# 📋 Open Assigned Issues')
    ..writeln()
    ..writeln('<!-- mdformat off(prevent table wrapping) -->')
    ..writeln('| Metric | Count | Description |')
    ..writeln('| :--- | :---: | :--- |')
    ..writeln(
      '| **Total Open Issues** | **${issues.length}** | '
      'Open issues assigned to ${options.user} |',
    )
    ..writeln(
      '| 🔗 **With Linked PRs** | **$withPrsCount** | '
      'Issues with linked or referenced pull requests |',
    )
    ..writeln(
      '| ⏳ **Updated < 7 Days** | **$recentCount** | '
      'Issues updated within the last week |',
    )
    ..writeln('<!-- mdformat on -->')
    ..writeln();

  if (issues.isEmpty) {
    buffer.writeln('No open assigned issues found. 🎉\n');
    return buffer.toString();
  }

  buffer
    ..writeln('### 📋 Issues Breakdown')
    ..writeln()
    ..writeln('<!-- mdformat off(prevent table wrapping) -->')
    ..writeln(
      '| Issue & Repository | Title | Labels | Last Updated | Linked PR(s) |',
    )
    ..writeln('| :--- | :--- | :--- | :--- | :--- |');

  for (final issue in issues) {
    final repoUrl = issue.repoUrl.isNotEmpty
        ? issue.repoUrl
        : 'https://github.com/${issue.repository}';
    final issueCell =
        '[#${issue.number}](${issue.url})<br>[${issue.repository}]($repoUrl)';

    final sanitizedTitle = issue.title
        .replaceAll('|', '/')
        .replaceAll('\n', ' ')
        .trim();

    final labelStr = _formatLabels(issue.labels);
    final touched = formatTouchedMarkdown(issue.updatedAt, currentTime: now);
    final prCell = _formatLinkedPrsMarkdown(issue);

    buffer.writeln(
      '| $issueCell | $sanitizedTitle | $labelStr | $touched | $prCell |',
    );
  }

  buffer
    ..writeln('<!-- mdformat on -->')
    ..writeln()
    ..writeln('*PR Legend: 🟢 Open | 🟣 Merged | 🔴 Closed*');

  return buffer.toString();
}

String _formatTerminalLinkedPr(LinkedPr pr, String issueRepo) {
  final icon = switch (pr.state) {
    'OPEN' => green.wrap('●') ?? '●',
    'MERGED' => magenta.wrap('●') ?? '●',
    'CLOSED' => red.wrap('●') ?? '●',
    _ => '○',
  };
  final label = pr.repository == issueRepo
      ? '#${pr.number}'
      : '${pr.repository}#${pr.number}';
  return '$icon $label (${pr.state})';
}

void _formatTerminalIssue(StringBuffer buffer, GhIssue issue, DateTime now) {
  final issueTag =
      styleBold.wrap('${issue.repository}#${issue.number}') ??
      '${issue.repository}#${issue.number}';
  final touched = formatTouchedTerminal(issue.updatedAt, currentTime: now);
  buffer
    ..writeln()
    ..writeln('$issueTag ($touched)')
    ..writeln('  Title: ${issue.title}')
    ..writeln('  URL: ${issue.url}');
  if (issue.labels.isNotEmpty) {
    buffer.writeln('  Labels: ${issue.labels.join(', ')}');
  }
  if (issue.linkedPrs.isNotEmpty) {
    final prStrs = issue.linkedPrs
        .map((pr) => _formatTerminalLinkedPr(pr, issue.repository))
        .join(', ');
    buffer.writeln('  Linked PRs: $prStrs');
  }
}

/// Renders colorized terminal output.
String renderTerminalReport(
  List<GhIssue> issues, {
  required GhIssuesOptions options,
  DateTime? currentTime,
}) {
  final now = currentTime ?? DateTime.now();
  final buffer = StringBuffer()
    ..writeln('''
======================================================================
${styleBold.wrap('📋 GITHUB ASSIGNED ISSUES OVERVIEW')}
======================================================================''');

  if (issues.isEmpty) {
    buffer.writeln('\nNo open assigned issues found. 🎉\n');
    return buffer.toString();
  }

  for (final issue in issues) {
    _formatTerminalIssue(buffer, issue, now);
  }

  final withPrsCount = issues.where((i) => i.linkedPrs.isNotEmpty).length;
  final recentCutoff = now.subtract(const Duration(days: 7));
  final recentCount = issues
      .where((i) => !i.updatedAt.isBefore(recentCutoff))
      .length;

  buffer.writeln('''

----------------------------------------------------------------------
${styleBold.wrap('Summary:')} Total Open: ${issues.length} | With Linked PRs: $withPrsCount | Updated < 7d: $recentCount
----------------------------------------------------------------------''');

  return buffer.toString();
}

/// Renders JSON output.
String renderJsonOutput(
  List<GhIssue> issues, {
  required GhIssuesOptions options,
  DateTime? currentTime,
}) {
  final now = currentTime ?? DateTime.now();
  final data = {
    'total': issues.length,
    'user': options.user,
    'generatedAt': now.toUtc().toIso8601String(),
    'issues': issues
        .map(
          (issue) => {
            'number': issue.number,
            'title': issue.title,
            'url': issue.url,
            'repository': issue.repository,
            'repoUrl': issue.repoUrl,
            'createdAt': issue.createdAt.toUtc().toIso8601String(),
            'updatedAt': issue.updatedAt.toUtc().toIso8601String(),
            'labels': issue.labels,
            'commentsCount': issue.commentsCount,
            'linkedPrs': issue.linkedPrs
                .map(
                  (pr) => {
                    'number': pr.number,
                    'url': pr.url,
                    'state': pr.state,
                    'repository': pr.repository,
                  },
                )
                .toList(),
          },
        )
        .toList(),
  };
  return const JsonEncoder.withIndent('  ').convert(data);
}

/// Main execution function for `gh-issues`.
Future<void> runGhIssues({
  required GhIssuesOptions options,
  ProcessRunner? processRunner,
  DateTime? now,
}) async {
  final currentTime = now ?? DateTime.now();

  final issues = await fetchAssignedIssues(
    user: options.user,
    repo: options.repo,
    limit: options.limit,
    lastNDays: options.lastNDays,
    createdDays: options.createdDays,
    checkLinkedPrs: options.checkLinkedPrs,
    processRunner: processRunner,
    now: currentTime,
  );

  if (options.json) {
    print(renderJsonOutput(issues, options: options, currentTime: currentTime));
  } else if (options.markdown) {
    print(
      renderMarkdownReport(issues, options: options, currentTime: currentTime),
    );
  } else {
    print(
      renderTerminalReport(issues, options: options, currentTime: currentTime),
    );
  }
}
