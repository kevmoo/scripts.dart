import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;

import 'local_repo_scanner.dart';
import 'process_utils.dart';

export 'local_repo_scanner.dart' show normalizeRepoName;

/// Exception thrown by `gh-view` operations.
class GhViewException implements Exception {
  final String message;
  final int exitCode;

  new(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}

/// Representation of an open GitHub Pull Request.
typedef GhPr = ({
  int number,
  String title,
  String url,
  bool isDraft,
  String state,
  String reviewDecision,
  List<String> requestedReviewers,
  int totalReviewThreads,
  int unresolvedReviewThreads,
  String mergeable,
  bool isInMergeQueue,
  String headRefName,
  String headRefOid,
  String baseRefName,
  String repository,
  String repoUrl,
  bool isRepoArchived,
  String ciStatus,
  DateTime updatedAt,
  LocalBranchStatus? localStatus,
  String? context,
});

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

  static ArgParser createArgParser() => ArgParser()
    ..addOption(
      'user',
      abbr: 'u',
      defaultsTo: '@me',
      help: 'The GitHub user to inspect.',
    )
    ..addOption(
      'repo',
      abbr: 'R',
      help: 'Filter PRs to a specific repository (owner/repo).',
    )
    ..addOption(
      'limit',
      abbr: 'l',
      defaultsTo: '50',
      help: 'Maximum number of PRs to retrieve.',
    )
    ..addOption(
      'last-n-days',
      abbr: 'd',
      aliases: ['last-days', 'days'],
      help: 'Filter PRs touched in the last N days (positive integer).',
    )
    ..addFlag('json', negatable: false, help: 'Output results in JSON format.')
    ..addFlag(
      'markdown',
      abbr: 'm',
      negatable: false,
      help: 'Output results as GitHub Flavored Markdown.',
    )
    ..addFlag(
      'local',
      defaultsTo: true,
      help: 'Cross-reference local workspace checkouts and worktrees.',
    )
    ..addOption(
      'local-root',
      help: 'Base directory for local Git repositories (defaults to ~/github).',
    )
    ..addOption(
      'enricher',
      abbr: 'e',
      help:
          'External command or script to enrich PRs with project/context '
          'metadata.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );
}

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

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
}) async => (
  number: pr.number,
  title: pr.title,
  url: pr.url,
  isDraft: pr.isDraft,
  state: pr.state,
  reviewDecision: pr.reviewDecision,
  requestedReviewers: pr.requestedReviewers,
  totalReviewThreads: pr.totalReviewThreads,
  unresolvedReviewThreads: pr.unresolvedReviewThreads,
  mergeable: pr.mergeable,
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

/// Fetches open PRs via GitHub GraphQL.
Future<List<GhPr>> fetchOpenPullRequests({
  required String user,
  String? repo,
  int limit = 50,
  ProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? Process.run;
  final searchQuery = _buildSearchQuery(user: user, repo: repo);

  const graphqlQuery = r'''
query($q: String!, $limit: Int!) {
  search(query: $q, type: ISSUE, first: $limit) {
    issueCount
    nodes {
      ... on PullRequest {
        number
        title
        url
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
        reviewThreads(first: 50) {
          totalCount
          nodes {
            isResolved
          }
        }
        mergeable
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

  final result = await runner('gh', [
    'api',
    'graphql',
    '-f',
    'query=$graphqlQuery',
    '-F',
    'q=$searchQuery',
    '-F',
    'limit=$limit',
  ]);

  if (result.exitCode != 0) {
    throw GhViewException(
      'Failed to fetch pull requests via GitHub CLI (gh).\n'
      'Make sure `gh` is installed and authenticated (`gh auth login`).\n'
      'Error: ${result.stderr}',
      exitCode: ExitCode.software.code,
    );
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(result.stdout as String);
  } catch (e) {
    throw GhViewException(
      'Failed to parse GitHub GraphQL response: $e\nOutput:\n${result.stdout}',
      exitCode: ExitCode.software.code,
    );
  }

  if (decoded is! Map<String, dynamic>) {
    throw GhViewException('Invalid GraphQL response structure.');
  }

  final data = decoded['data'] as Map<String, dynamic>?;
  final search = data?['search'] as Map<String, dynamic>?;
  final nodes = search?['nodes'] as List<dynamic>? ?? [];

  return nodes
      .whereType<Map<String, dynamic>>()
      .map(parsePrNode)
      .whereType<GhPr>()
      .toList();
}

String _buildSearchQuery({required String user, String? repo}) {
  final buffer = StringBuffer('is:pr is:open');
  if (user.isNotEmpty) buffer.write(' author:$user');
  if (repo != null && repo.isNotEmpty) buffer.write(' repo:$repo');
  buffer.write(' sort:updated-desc');
  return buffer.toString();
}

/// Parses a single PR node from GraphQL.
GhPr? parsePrNode(Map<String, dynamic> node) {
  final number = node['number'] as int?;
  final title = node['title'] as String?;
  final url = node['url'] as String?;
  final repoMap = node['repository'] as Map<String, dynamic>?;
  final repository = repoMap?['nameWithOwner'] as String? ?? '';

  if (number == null || title == null || url == null || repository.isEmpty) {
    return null;
  }

  final updatedAtStr = node['updatedAt'] as String?;
  final updatedAt = updatedAtStr != null
      ? DateTime.tryParse(updatedAtStr) ?? DateTime.now()
      : DateTime.now();

  final requestedReviewers = _extractRequestedReviewers(
    node['reviewRequests'] as Map<String, dynamic>?,
  );
  final threads = _extractReviewThreads(
    node['reviewThreads'] as Map<String, dynamic>?,
  );
  final ciStatus = _extractCiStatus(
    repository,
    node['commits'] as Map<String, dynamic>?,
  );

  return (
    number: number,
    title: title,
    url: url,
    isDraft: node['isDraft'] as bool? ?? false,
    state: node['state'] as String? ?? 'OPEN',
    reviewDecision: node['reviewDecision'] as String? ?? 'NONE',
    requestedReviewers: requestedReviewers,
    totalReviewThreads: threads.total,
    unresolvedReviewThreads: threads.unresolved,
    mergeable: node['mergeable'] as String? ?? 'UNKNOWN',
    isInMergeQueue: node['isInMergeQueue'] as bool? ?? false,
    headRefName: node['headRefName'] as String? ?? '',
    headRefOid: node['headRefOid'] as String? ?? '',
    baseRefName: node['baseRefName'] as String? ?? '',
    repository: repository,
    repoUrl: repoMap?['url'] as String? ?? '',
    isRepoArchived: repoMap?['isArchived'] as bool? ?? false,
    ciStatus: ciStatus,
    updatedAt: updatedAt,
    localStatus: null,
    context: null,
  );
}

List<String> _extractRequestedReviewers(
  Map<String, dynamic>? reviewRequestsObj,
) {
  final requestNodes = reviewRequestsObj?['nodes'] as List<dynamic>? ?? [];
  final reviewers = <String>[];
  for (final r in requestNodes) {
    if (r is Map<String, dynamic>) {
      final reviewer = r['requestedReviewer'] as Map<String, dynamic>?;
      final login =
          reviewer?['login'] as String? ??
          reviewer?['slug'] as String? ??
          reviewer?['name'] as String?;
      if (login != null && login.isNotEmpty) {
        reviewers.add(login);
      }
    }
  }
  return reviewers;
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

String _extractCiStatus(String repository, Map<String, dynamic>? commits) {
  final commitNodes = commits?['nodes'] as List<dynamic>?;
  if (commitNodes == null || commitNodes.isEmpty) return 'NONE';

  final firstCommit = commitNodes.first as Map<String, dynamic>?;
  final commitObj = firstCommit?['commit'] as Map<String, dynamic>?;
  final statusRollup = commitObj?['statusCheckRollup'] as Map<String, dynamic>?;
  final rawState = statusRollup?['state'] as String? ?? 'NONE';

  if (repository.toLowerCase() == 'flutter/flutter' && rawState == 'FAILURE') {
    if (_isFlutterTreeStatusOnlyFailure(statusRollup)) {
      return 'TREE_BROKEN';
    }
  }

  return rawState;
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
    if (state == 'FAILURE' || state == 'ERROR') {
      final contextName = ctx['context'] as String? ?? '';
      return contextName == 'tree-status'
          ? _FlutterContextStatus.treeStatusFailure
          : _FlutterContextStatus.realFailure;
    }
    return _FlutterContextStatus.ok;
  }
  if (typename == 'CheckRun') {
    final conclusion = ctx['conclusion'] as String? ?? '';
    if (conclusion == 'FAILURE' ||
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
  final repo = localRepos
      .where((r) => r.repoNames.any((n) => n.toLowerCase() == repoKey))
      .firstOrNull;
  if (repo == null) return null;

  final wtMatch = repo.worktrees
      .where((wt) => wt.branch == pr.headRefName)
      .firstOrNull;
  final branchMatch = repo.branches
      .where((b) => b.name == pr.headRefName)
      .firstOrNull;

  if (wtMatch == null && branchMatch == null) return null;

  final repoPath = wtMatch != null ? wtMatch.path : repo.repoPath;
  final sha = wtMatch != null ? wtMatch.sha : branchMatch!.sha;
  final isWorktree = wtMatch != null;

  final shortSha = sha.length >= 7 ? sha.substring(0, 7) : sha;
  final isHeadMatching =
      pr.headRefOid.isNotEmpty &&
      (sha == pr.headRefOid || pr.headRefOid.startsWith(sha));

  final isDirty = await isRepoDirty(repoPath, processRunner: processRunner);
  var display = isHeadMatching ? '🟢 Synced' : '⚠️ Diverged';
  if (isDirty) display = '$display (Dirty)';

  return (
    repoPath: repoPath,
    branchName: pr.headRefName,
    shortSha: shortSha,
    isDirty: isDirty,
    isHeadMatching: isHeadMatching,
    isWorktree: isWorktree,
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
  final isApproved = pr.reviewDecision == 'APPROVED';
  final isCiSuccess = pr.ciStatus == 'SUCCESS' || pr.ciStatus == 'TREE_BROKEN';
  final isMergeable = pr.mergeable == 'MERGEABLE' || pr.isInMergeQueue;
  return isApproved && isCiSuccess && isMergeable;
}

bool _isActionNeeded(GhPr pr) {
  final isChangesRequested =
      pr.reviewDecision == 'CHANGES_REQUESTED' && pr.requestedReviewers.isEmpty;
  final isCiFailure = pr.ciStatus == 'FAILURE';
  final isConflicting = pr.mergeable == 'CONFLICTING';
  return isChangesRequested || isCiFailure || isConflicting;
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
  if (pr.mergeable == 'CONFLICTING') {
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
  if (pr.reviewDecision == 'APPROVED') {
    return green.wrap('Approved') ?? 'Approved';
  }
  if (pr.reviewDecision == 'CHANGES_REQUESTED') {
    if (pr.requestedReviewers.isNotEmpty) {
      return yellow.wrap(
            'Re-review Requested (@${pr.requestedReviewers.join(', @')})',
          ) ??
          'Re-review Requested';
    }
    if (pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0) {
      return yellow.wrap('Changes Requested (Resolved: Re-review Needed)') ??
          'Changes Requested (Resolved: Re-review Needed)';
    }
    return red.wrap('Changes Requested') ?? 'Changes Requested';
  }
  if (pr.reviewDecision == 'REVIEW_REQUIRED') {
    if (pr.requestedReviewers.isNotEmpty) {
      return yellow.wrap(
            'Review Required (@${pr.requestedReviewers.join(', @')})',
          ) ??
          'Review Required';
    }
    return yellow.wrap('Review Required') ?? 'Review Required';
  }
  return 'No Reviewers';
}

String _formatCiBadgeTerminal(GhPr pr) => switch (pr.ciStatus) {
  'SUCCESS' => green.wrap('CI: Passing') ?? 'CI: Passing',
  'TREE_BROKEN' =>
    yellow.wrap('CI: Tree Broken (PR Clean)') ?? 'CI: Tree Broken (PR Clean)',
  'FAILURE' => red.wrap('CI: Failing') ?? 'CI: Failing',
  'PENDING' => yellow.wrap('CI: Pending') ?? 'CI: Pending',
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
    includeIssueType: true,
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
    isDraftSection: true,
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
  bool includeIssueType = false,
  bool isDraftSection = false,
}) {
  if (prs.isEmpty) return;
  const tableHeader = '''
<!-- mdformat off(prevent table wrapping) -->
| Pull Request | Status |
| :--- | :--- |''';

  buffer
    ..writeln(title)
    ..writeln()
    ..writeln(tableHeader);
  for (final pr in prs) {
    _writeMarkdownPrRow(
      buffer,
      pr,
      now,
      includeIssueType: includeIssueType,
      isDraftSection: isDraftSection,
    );
  }
  buffer
    ..writeln('<!-- mdformat on -->')
    ..writeln();
}

void _writeMarkdownPrRow(
  StringBuffer buffer,
  GhPr pr,
  DateTime now, {
  bool includeIssueType = false,
  bool isDraftSection = false,
}) {
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
    '`${pr.headRefName}`',
    _formatLocalMappingMarkdown(pr.localStatus),
  ];

  final areThreadsResolved =
      pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0;
  final statusLines = <String>[];

  if (includeIssueType) {
    statusLines.add('Issue: ${_resolveIssueType(pr, areThreadsResolved)}');
  }

  statusLines
    ..add('Review: ${_formatReviewBadgeMarkdown(pr, areThreadsResolved)}')
    ..add('CI: ${_formatCiBadgeMarkdown(pr.ciStatus)}');

  final mergeableCell = _formatMergeableBadgeMarkdown(pr);
  statusLines.add('Merge: $mergeableCell');

  final touched = formatTouchedMarkdown(pr.updatedAt, currentTime: now);
  statusLines.add('Touched: $touched');

  final prCell = prLines.join('<br>');
  final statusCell = statusLines
      .map((line) => line.replaceAll(' ', '&nbsp;'))
      .join('<br>');

  buffer.writeln('| $prCell | $statusCell |');
}

String _resolveIssueType(GhPr pr, bool areThreadsResolved) => switch ((
  pr.reviewDecision == 'CHANGES_REQUESTED',
  pr.requestedReviewers.isNotEmpty,
  areThreadsResolved,
  pr.ciStatus == 'FAILURE',
  pr.mergeable == 'CONFLICTING',
)) {
  (true, true, _, _, _) => '🟡 Re-review Requested',
  (true, false, true, _, _) => '🔄 Re-review Needed',
  (true, false, false, _, _) => '🔴 Changes Requested',
  (_, _, _, true, _) => '🔴 CI Failing',
  (_, _, _, _, true) => '⚠️ Conflicting',
  _ => '🟡 Attention Needed',
};

String _formatReviewBadgeMarkdown(GhPr pr, bool areThreadsResolved) {
  if (pr.reviewDecision == 'APPROVED') return '🟢 Approved';
  if (pr.reviewDecision == 'CHANGES_REQUESTED') {
    if (pr.requestedReviewers.isNotEmpty) {
      return '🟡 Re-review Requested (@${pr.requestedReviewers.join(', @')})';
    }
    if (areThreadsResolved) return '🔴 Changes Requested (Resolved)';
    if (pr.unresolvedReviewThreads > 0) {
      return '🔴 Changes Requested (${pr.unresolvedReviewThreads} open)';
    }
    return '🔴 Changes Requested';
  }
  if (pr.reviewDecision == 'REVIEW_REQUIRED') {
    if (pr.requestedReviewers.isNotEmpty) {
      return '🟡 Review Required (@${pr.requestedReviewers.join(', @')})';
    }
    return '🟡 Review Required';
  }
  return '⚪ None';
}

String _formatCiBadgeMarkdown(String ciStatus) => switch (ciStatus) {
  'SUCCESS' => '🟢 Passing',
  'TREE_BROKEN' => '🟠 Tree Broken (PR Clean)',
  'FAILURE' => '🔴 Failing',
  'PENDING' => '⏳ Pending',
  _ => '⚪ None',
};

String _formatMergeableBadgeMarkdown(GhPr pr) {
  final label = switch (pr.mergeable) {
    'MERGEABLE' => '✅ Yes',
    'CONFLICTING' => '⚠️ Conflicting',
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
    'repository': pr.repository,
    'repoUrl': pr.repoUrl,
    'isRepoArchived': pr.isRepoArchived,
    'isDraft': pr.isDraft,
    'state': pr.state,
    'reviewDecision': pr.reviewDecision,
    'requestedReviewers': pr.requestedReviewers,
    'totalReviewThreads': pr.totalReviewThreads,
    'unresolvedReviewThreads': pr.unresolvedReviewThreads,
    'areAllReviewThreadsResolved':
        pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0,
    'ciStatus': pr.ciStatus,
    'mergeable': pr.mergeable,
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
