import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;

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
  final bool json;
  final bool markdown;
  final bool checkLocal;
  final String? localRoot;

  const new({
    this.user = '@me',
    this.repo,
    this.limit = 50,
    this.json = false,
    this.markdown = false,
    this.checkLocal = true,
    this.localRoot,
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

/// Main execution function for `gh-view`.
Future<void> runGhView({
  required GhViewOptions options,
  ProcessRunner? processRunner,
  DateTime? now,
}) async {
  final runner = processRunner ?? Process.run;
  final currentTime = now ?? DateTime.now();

  // 1. Fetch PRs from GitHub GraphQL
  final rawPrs = await fetchOpenPullRequests(
    user: options.user,
    repo: options.repo,
    limit: options.limit,
    processRunner: runner,
  );

  // 2. Scan local workspaces if enabled
  Map<String, List<LocalBranchInfo>>? localMap;
  if (options.checkLocal) {
    final localRootPath =
        options.localRoot ?? '${Platform.environment['HOME'] ?? ''}/github';
    if (localRootPath.isNotEmpty && Directory(localRootPath).existsSync()) {
      localMap = scanLocalRepositories(Directory(localRootPath));
    }
  }

  // 3. Attach local status to PRs
  final prs = rawPrs.map((pr) {
    final localStatus = _matchLocalStatus(pr, localMap);
    return (
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
      localStatus: localStatus,
    );
  }).toList();

  // 4. Output results
  if (options.json) {
    print(renderJsonOutput(prs, currentTime: currentTime));
  } else if (options.markdown) {
    print(renderMarkdownReport(prs, currentTime: currentTime));
  } else {
    print(renderTerminalReport(prs, currentTime: currentTime));
  }
}

/// Fetches open PRs via GitHub GraphQL.
Future<List<GhPr>> fetchOpenPullRequests({
  required String user,
  String? repo,
  int limit = 50,
  ProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? Process.run;

  var searchQuery = 'is:pr is:open';
  if (user.isNotEmpty) {
    searchQuery += ' author:$user';
  }
  if (repo != null && repo.isNotEmpty) {
    searchQuery += ' repo:$repo';
  }
  searchQuery += ' sort:updated-desc';

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

  final prs = <GhPr>[];
  for (final node in nodes) {
    if (node is! Map<String, dynamic>) continue;
    final parsed = parsePrNode(node);
    if (parsed != null) {
      prs.add(parsed);
    }
  }

  return prs;
}

/// Parses a single PR node from GraphQL.
GhPr? parsePrNode(Map<String, dynamic> node) {
  final number = node['number'] as int?;
  final title = node['title'] as String?;
  final url = node['url'] as String?;
  final isDraft = node['isDraft'] as bool? ?? false;
  final state = node['state'] as String? ?? 'OPEN';
  final reviewDecision = node['reviewDecision'] as String? ?? 'NONE';
  final mergeable = node['mergeable'] as String? ?? 'UNKNOWN';
  final isInMergeQueue = node['isInMergeQueue'] as bool? ?? false;
  final headRefName = node['headRefName'] as String? ?? '';
  final headRefOid = node['headRefOid'] as String? ?? '';
  final baseRefName = node['baseRefName'] as String? ?? '';
  final updatedAtStr = node['updatedAt'] as String?;
  final repoMap = node['repository'] as Map<String, dynamic>?;
  final repository = repoMap?['nameWithOwner'] as String? ?? '';
  final repoUrl = repoMap?['url'] as String? ?? '';
  final isRepoArchived = repoMap?['isArchived'] as bool? ?? false;

  if (number == null || title == null || url == null || repository.isEmpty) {
    return null;
  }

  final updatedAt = updatedAtStr != null
      ? DateTime.tryParse(updatedAtStr) ?? DateTime.now()
      : DateTime.now();

  // Parse review requests
  final reviewRequestsObj = node['reviewRequests'] as Map<String, dynamic>?;
  final requestNodes = reviewRequestsObj?['nodes'] as List<dynamic>? ?? [];
  final requestedReviewers = <String>[];
  for (final r in requestNodes) {
    if (r is Map<String, dynamic>) {
      final reviewer = r['requestedReviewer'] as Map<String, dynamic>?;
      final login =
          reviewer?['login'] as String? ??
          reviewer?['slug'] as String? ??
          reviewer?['name'] as String?;
      if (login != null && login.isNotEmpty) {
        requestedReviewers.add(login);
      }
    }
  }

  // Parse review threads
  final reviewThreadsObj = node['reviewThreads'] as Map<String, dynamic>?;
  final totalThreads = reviewThreadsObj?['totalCount'] as int? ?? 0;
  final threadNodes = reviewThreadsObj?['nodes'] as List<dynamic>? ?? [];
  var unresolvedThreads = 0;
  for (final t in threadNodes) {
    if (t is Map<String, dynamic> && t['isResolved'] == false) {
      unresolvedThreads++;
    }
  }

  var ciStatus = 'NONE';
  final commits = node['commits'] as Map<String, dynamic>?;
  final commitNodes = commits?['nodes'] as List<dynamic>?;
  if (commitNodes != null && commitNodes.isNotEmpty) {
    final firstCommit = commitNodes.first as Map<String, dynamic>?;
    final commitObj = firstCommit?['commit'] as Map<String, dynamic>?;
    final statusRollup =
        commitObj?['statusCheckRollup'] as Map<String, dynamic>?;
    final rawState = statusRollup?['state'] as String? ?? 'NONE';

    if (repository.toLowerCase() == 'flutter/flutter' &&
        rawState == 'FAILURE') {
      final contexts = statusRollup?['contexts'] as Map<String, dynamic>?;
      final contextNodes = contexts?['nodes'] as List<dynamic>? ?? [];

      var hasRealFailure = false;
      var hasTreeStatusFailure = false;

      for (final ctx in contextNodes) {
        if (ctx is! Map<String, dynamic>) continue;
        final typename = ctx['__typename'] as String?;
        if (typename == 'StatusContext') {
          final contextName = ctx['context'] as String? ?? '';
          final state = ctx['state'] as String? ?? '';
          if (state == 'FAILURE' || state == 'ERROR') {
            if (contextName == 'tree-status') {
              hasTreeStatusFailure = true;
            } else {
              hasRealFailure = true;
            }
          }
        } else if (typename == 'CheckRun') {
          final conclusion = ctx['conclusion'] as String? ?? '';
          if (conclusion == 'FAILURE' ||
              conclusion == 'TIMED_OUT' ||
              conclusion == 'CANCELLED') {
            hasRealFailure = true;
          }
        }
      }

      if (hasTreeStatusFailure && !hasRealFailure) {
        ciStatus = 'TREE_BROKEN';
      } else {
        ciStatus = rawState;
      }
    } else {
      ciStatus = rawState;
    }
  }

  return (
    number: number,
    title: title,
    url: url,
    isDraft: isDraft,
    state: state,
    reviewDecision: reviewDecision,
    requestedReviewers: requestedReviewers,
    totalReviewThreads: totalThreads,
    unresolvedReviewThreads: unresolvedThreads,
    mergeable: mergeable,
    isInMergeQueue: isInMergeQueue,
    headRefName: headRefName,
    headRefOid: headRefOid,
    baseRefName: baseRefName,
    repository: repository,
    repoUrl: repoUrl,
    isRepoArchived: isRepoArchived,
    ciStatus: ciStatus,
    updatedAt: updatedAt,
    localStatus: null,
  );
}

/// Metadata discovered about local Git repositories.
typedef LocalBranchInfo = ({
  String repoName,
  String repoPath,
  String branchName,
  String sha,
  bool isWorktree,
});

/// Scans local directories under [root] for Git repositories and worktrees.
Map<String, List<LocalBranchInfo>> scanLocalRepositories(
  Directory root, {
  ProcessRunner? processRunner,
}) {
  final map = <String, List<LocalBranchInfo>>{};

  void checkDir(Directory dir) {
    final gitEntity = FileSystemEntity.typeSync('${dir.path}/.git');
    if (gitEntity != FileSystemEntityType.notFound) {
      _indexGitRepo(dir, map);
    }
  }

  try {
    for (final entity in root.listSync().whereType<Directory>()) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;

      final isGit =
          FileSystemEntity.typeSync('${entity.path}/.git') !=
          FileSystemEntityType.notFound;
      if (isGit) {
        checkDir(entity);
      } else {
        // Check 1 level deeper (e.g. ~/github/dart-lang/*, ~/github/kevmoo/*)
        try {
          for (final sub in entity.listSync().whereType<Directory>()) {
            final subName = p.basename(sub.path);
            if (!subName.startsWith('.')) {
              checkDir(sub);
            }
          }
        } catch (_) {}
      }
    }
  } catch (_) {}

  return map;
}

void _indexGitRepo(Directory dir, Map<String, List<LocalBranchInfo>> map) {
  final originResult = Process.runSync('git', [
    'remote',
    'get-url',
    'origin',
  ], workingDirectory: dir.path);
  if (originResult.exitCode != 0) return;

  final repoName = normalizeRepoName(originResult.stdout as String);
  if (repoName == null) return;

  final branchResult = Process.runSync('git', [
    'for-each-ref',
    '--format=%(refname:short)\t%(objectname)',
    'refs/heads/',
  ], workingDirectory: dir.path);

  final branches = <LocalBranchInfo>[];
  if (branchResult.exitCode == 0) {
    for (final line in (branchResult.stdout as String).trim().split('\n')) {
      if (line.isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length == 2) {
        branches.add((
          repoName: repoName,
          repoPath: dir.path,
          branchName: parts[0],
          sha: parts[1],
          isWorktree: false,
        ));
      }
    }
  }

  // Also check active worktrees
  final wtResult = Process.runSync('git', [
    'worktree',
    'list',
    '--porcelain',
  ], workingDirectory: dir.path);
  if (wtResult.exitCode == 0) {
    String? currentWtPath;
    String? currentBranch;
    String? currentSha;

    for (final line in (wtResult.stdout as String).trim().split('\n')) {
      if (line.startsWith('worktree ')) {
        currentWtPath = line.substring('worktree '.length).trim();
      } else if (line.startsWith('HEAD ')) {
        currentSha = line.substring('HEAD '.length).trim();
      } else if (line.startsWith('branch refs/heads/')) {
        currentBranch = line.substring('branch refs/heads/'.length).trim();
      } else if (line.isEmpty) {
        if (currentWtPath != null && currentBranch != null) {
          branches.add((
            repoName: repoName,
            repoPath: currentWtPath,
            branchName: currentBranch,
            sha: currentSha ?? '',
            isWorktree: true,
          ));
        }
        currentWtPath = null;
        currentBranch = null;
        currentSha = null;
      }
    }
    if (currentWtPath != null && currentBranch != null) {
      branches.add((
        repoName: repoName,
        repoPath: currentWtPath,
        branchName: currentBranch,
        sha: currentSha ?? '',
        isWorktree: true,
      ));
    }
  }

  map.putIfAbsent(repoName.toLowerCase(), () => []).addAll(branches);
}

/// Normalizes a remote Git URL to `owner/repo`.
String? normalizeRepoName(String raw) {
  var url = raw.trim();
  if (url.startsWith('git@github.com:')) {
    url = url.substring('git@github.com:'.length);
  } else if (url.startsWith('https://github.com/')) {
    url = url.substring('https://github.com/'.length);
  } else {
    return null;
  }
  if (url.endsWith('.git')) {
    url = url.substring(0, url.length - 4);
  }
  return url.trim();
}

LocalBranchStatus? _matchLocalStatus(
  GhPr pr,
  Map<String, List<LocalBranchInfo>>? localMap,
) {
  if (localMap == null) return null;

  final repoKey = pr.repository.toLowerCase();
  final branches = localMap[repoKey];
  if (branches == null || branches.isEmpty) return null;

  final match = branches
      .where((b) => b.branchName == pr.headRefName)
      .firstOrNull;
  if (match == null) return null;

  final shortSha = match.sha.length >= 7
      ? match.sha.substring(0, 7)
      : match.sha;
  final isHeadMatching =
      pr.headRefOid.isNotEmpty &&
      (match.sha == pr.headRefOid || pr.headRefOid.startsWith(match.sha));

  // Check dirty status
  var isDirty = false;
  try {
    final statusRes = Process.runSync('git', [
      'status',
      '--porcelain',
      '-uno',
    ], workingDirectory: match.repoPath);
    if (statusRes.exitCode == 0) {
      isDirty = (statusRes.stdout as String).trim().isNotEmpty;
    }
  } catch (_) {}

  var display = isHeadMatching ? '🟢 Synced' : '⚠️ Diverged';
  if (isDirty) {
    display = '$display (Dirty)';
  }

  return (
    repoPath: match.repoPath,
    branchName: match.branchName,
    shortSha: shortSha,
    isDirty: isDirty,
    isHeadMatching: isHeadMatching,
    isWorktree: match.isWorktree,
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
      continue;
    }

    if (pr.isDraft) {
      drafts.add(pr);
      continue;
    }

    final isApproved = pr.reviewDecision == 'APPROVED';
    final isCiSuccess =
        pr.ciStatus == 'SUCCESS' || pr.ciStatus == 'TREE_BROKEN';
    final isMergeable = pr.mergeable == 'MERGEABLE' || pr.isInMergeQueue;
    final isChangesRequested =
        pr.reviewDecision == 'CHANGES_REQUESTED' &&
        pr.requestedReviewers.isEmpty;
    final isCiFailure = pr.ciStatus == 'FAILURE';
    final isConflicting = pr.mergeable == 'CONFLICTING';

    if (isApproved && isCiSuccess && isMergeable) {
      readyToMerge.add(pr);
    } else if (isChangesRequested || isCiFailure || isConflicting) {
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

/// Formats the last touched time relative to [currentTime].
///
/// Returns `# of hours up to 24, then number of days`.
String formatTimeAgo(DateTime dateTime, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final diff = now.difference(dateTime);

  if (diff.isNegative) return 'just now';

  final hours = diff.inHours;
  if (hours < 1) {
    final minutes = diff.inMinutes;
    return minutes <= 1 ? 'just now' : '${minutes}m ago';
  }

  if (hours <= 24) {
    return '${hours}h ago';
  }

  final days = diff.inDays;
  return '${days}d ago';
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
  if (days < 7) {
    return TouchedColor.green;
  }
  if (days < 14) {
    return TouchedColor.yellow;
  }
  if (days <= 28) {
    return TouchedColor.orange;
  }
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

  // 1. Ready to Merge
  if (categorized.readyToMerge.isNotEmpty) {
    buffer
      ..writeln('\n${green.wrap(styleBold.wrap('🚀 READY TO MERGE')!)}')
      ..writeln(
        styleDim.wrap('   Approved by reviewers and all CI checks passing:')!,
      );
    for (final pr in categorized.readyToMerge) {
      _writePrItem(buffer, pr, now);
    }
  }

  // 2. Action Needed
  if (categorized.actionNeeded.isNotEmpty) {
    final header = red.wrap(
      styleBold.wrap('⚠️  ACTION NEEDED (Blocked / Failing / Conflicts)')!,
    );
    buffer
      ..writeln('\n$header')
      ..writeln(
        styleDim.wrap(
          '   Requires code fixes, rebase, or review feedback resolution:',
        )!,
      );
    for (final pr in categorized.actionNeeded) {
      _writePrItem(buffer, pr, now);
    }
  }

  // 3. In Review
  if (categorized.inReview.isNotEmpty) {
    buffer
      ..writeln('\n${yellow.wrap(styleBold.wrap('🟡 IN REVIEW QUEUE')!)}')
      ..writeln(styleDim.wrap('   Active PRs awaiting reviewer feedback:')!);
    for (final pr in categorized.inReview) {
      _writePrItem(buffer, pr, now);
    }
  }

  // 4. Drafts & WIP
  if (categorized.drafts.isNotEmpty) {
    buffer.writeln(
      '\n${styleDim.wrap(styleBold.wrap('⚪ DRAFTS & WORK IN PROGRESS')!)}',
    );
    for (final pr in categorized.drafts) {
      _writePrItem(buffer, pr, now);
    }
  }

  // 5. Archived Repositories
  if (categorized.archived.isNotEmpty) {
    final archivedHeader = styleDim.wrap(
      styleBold.wrap('📦 ARCHIVED REPOSITORIES (Read-Only)')!,
    );
    buffer
      ..writeln('\n$archivedHeader')
      ..writeln(
        styleDim.wrap(
          '   Repositories are archived; pull requests cannot be modified:',
        )!,
      );
    for (final pr in categorized.archived) {
      _writePrItem(buffer, pr, now);
    }
  }

  // Summary footer
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

  final reviewBadge = switch (pr.reviewDecision) {
    'APPROVED' => green.wrap('Approved') ?? 'Approved',
    'CHANGES_REQUESTED' =>
      pr.requestedReviewers.isNotEmpty
          ? yellow.wrap(
                  'Re-review Requested (@${pr.requestedReviewers.join(', @')})',
                ) ??
                'Re-review Requested'
          : pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0
          ? yellow.wrap('Changes Requested (Resolved: Re-review Needed)') ??
                'Changes Requested (Resolved: Re-review Needed)'
          : red.wrap('Changes Requested') ?? 'Changes Requested',
    'REVIEW_REQUIRED' =>
      pr.requestedReviewers.isNotEmpty
          ? yellow.wrap(
                  'Review Required (@${pr.requestedReviewers.join(', @')})',
                ) ??
                'Review Required'
          : yellow.wrap('Review Required') ?? 'Review Required',
    _ => 'No Reviewers',
  };
  statusBadges.add(reviewBadge);

  final ciBadge = switch (pr.ciStatus) {
    'SUCCESS' => green.wrap('CI: Passing') ?? 'CI: Passing',
    'TREE_BROKEN' =>
      yellow.wrap('CI: Tree Broken (PR Clean)') ?? 'CI: Tree Broken (PR Clean)',
    'FAILURE' => red.wrap('CI: Failing') ?? 'CI: Failing',
    'PENDING' => yellow.wrap('CI: Pending') ?? 'CI: Pending',
    _ => styleDim.wrap('CI: None') ?? 'CI: None',
  };
  statusBadges.add(ciBadge);

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

  if (pr.localStatus != null) {
    final loc = pr.localStatus!;
    final locDesc = p.basename(loc.repoPath);
    final wtTag = loc.isWorktree ? ' (worktree)' : '';
    buffer.writeln(
      '    Local:   ${loc.displayStatus} [$locDesc$wtTag at ${loc.repoPath}]',
    );
  }
}

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

  const tableHeader = '''
<!-- mdformat off(prevent table wrapping) -->
| Pull Request | Status |
| :--- | :--- |''';

  // 1. Ready to Merge
  if (categorized.readyToMerge.isNotEmpty) {
    buffer
      ..writeln('## 🚀 1. Ready to Merge (Approved + Green CI + Mergeable)')
      ..writeln()
      ..writeln(tableHeader);
    for (final pr in categorized.readyToMerge) {
      _writeMarkdownPrRow(buffer, pr, now);
    }
    buffer
      ..writeln('<!-- mdformat on -->')
      ..writeln();
  }

  // 2. Action Needed
  if (categorized.actionNeeded.isNotEmpty) {
    buffer
      ..writeln(
        '## ⚠️ 2. Action Needed '
        '(Blocked / Failing CI / Conflicts / Changes Requested)',
      )
      ..writeln()
      ..writeln(tableHeader);
    for (final pr in categorized.actionNeeded) {
      _writeMarkdownPrRow(buffer, pr, now, includeIssueType: true);
    }
    buffer
      ..writeln('<!-- mdformat on -->')
      ..writeln();
  }

  // 3. In Review
  if (categorized.inReview.isNotEmpty) {
    buffer
      ..writeln('## 🟡 3. In Review Queue (Green CI + Active Review)')
      ..writeln()
      ..writeln(tableHeader);
    for (final pr in categorized.inReview) {
      _writeMarkdownPrRow(buffer, pr, now);
    }
    buffer
      ..writeln('<!-- mdformat on -->')
      ..writeln();
  }

  // 4. Drafts & WIP
  if (categorized.drafts.isNotEmpty) {
    buffer
      ..writeln(
        '## ⚪ 4. Drafts & Work In Progress (${categorized.drafts.length} PRs)',
      )
      ..writeln()
      ..writeln(tableHeader);
    for (final pr in categorized.drafts) {
      _writeMarkdownPrRow(buffer, pr, now, isDraftSection: true);
    }
    buffer
      ..writeln('<!-- mdformat on -->')
      ..writeln();
  }

  // 5. Archived Repositories
  if (categorized.archived.isNotEmpty) {
    buffer
      ..writeln(
        '## 📦 5. Archived Repositories (Read-Only) '
        '(${categorized.archived.length} PRs)',
      )
      ..writeln()
      ..writeln(tableHeader);
    for (final pr in categorized.archived) {
      _writeMarkdownPrRow(buffer, pr, now);
    }
    buffer
      ..writeln('<!-- mdformat on -->')
      ..writeln();
  }

  return buffer.toString();
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
  final repoCell = '[${pr.repository}]($repoUrl)';
  final sanitizedTitle = pr.title
      .replaceAll('|', '/')
      .replaceAll('\n', ' ')
      .trim();
  final queuePrefix = pr.isInMergeQueue ? '`[🔀 Merge Queue]` ' : '';
  final prTitleLine = '[#${pr.number}](${pr.url}) $queuePrefix$sanitizedTitle';

  final prLines = <String>[repoCell, prTitleLine, '`${pr.headRefName}`'];

  if (pr.localStatus != null) {
    final loc = pr.localStatus!;
    final dirName = p.basename(loc.repoPath);
    prLines.add(
      'Local: ${loc.displayStatus} ([$dirName](file://${loc.repoPath}))',
    );
  } else {
    prLines.add('Local: ⚪ Not checked out');
  }

  final prCell = prLines.join('<br>');

  final areThreadsResolved =
      pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0;

  final statusLines = <String>[];

  if (includeIssueType) {
    final issueType = switch ((
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
    statusLines.add('Issue: $issueType');
  }

  final reviewCell = switch (pr.reviewDecision) {
    'APPROVED' => '🟢 Approved',
    'CHANGES_REQUESTED' =>
      pr.requestedReviewers.isNotEmpty
          ? '🟡 Re-review Requested (@${pr.requestedReviewers.join(', @')})'
          : areThreadsResolved
          ? '🔴 Changes Requested (Resolved)'
          : pr.unresolvedReviewThreads > 0
          ? '🔴 Changes Requested (${pr.unresolvedReviewThreads} open)'
          : '🔴 Changes Requested',
    'REVIEW_REQUIRED' =>
      pr.requestedReviewers.isNotEmpty
          ? '🟡 Review Required (@${pr.requestedReviewers.join(', @')})'
          : '🟡 Review Required',
    _ => '⚪ None',
  };
  statusLines.add('Review: $reviewCell');

  final ciCell = switch (pr.ciStatus) {
    'SUCCESS' => '🟢 Passing',
    'TREE_BROKEN' => '🟠 Tree Broken (PR Clean)',
    'FAILURE' => '🔴 Failing',
    'PENDING' => '⏳ Pending',
    _ => '⚪ None',
  };
  statusLines.add('CI: $ciCell');

  final mergeableCell = switch (pr.mergeable) {
    'MERGEABLE' => '✅ Yes',
    'CONFLICTING' => '⚠️ Conflicting',
    _ => pr.isInMergeQueue ? '✅ Yes' : '⚪ Unknown',
  };
  if (pr.isInMergeQueue) {
    statusLines.add('Merge: $mergeableCell (🔀 Queue)');
  } else {
    statusLines.add('Merge: $mergeableCell');
  }

  final touched = formatTouchedMarkdown(pr.updatedAt, currentTime: now);
  statusLines.add('Touched: $touched');

  final statusCell = statusLines
      .map((line) => line.replaceAll(' ', '&nbsp;'))
      .join('<br>');

  buffer.writeln('| $prCell | $statusCell |');
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
