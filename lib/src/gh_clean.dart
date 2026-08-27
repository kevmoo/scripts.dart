import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import 'local_repo_scanner.dart';
import 'process_utils.dart';

/// Exception thrown by `gh-clean` operations.
class GhCleanException implements Exception {
  final String message;
  final int exitCode;

  new(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}

/// Representation of a merged GitHub Pull Request.
typedef LandedPr = ({
  int number,
  String title,
  String url,
  String repository,
  String repoUrl,
  String headRefName,
  String headRefOid,
  String baseRefName,
  String? mergeSha,
  DateTime? mergedAt,
  DateTime? closedAt,
});

/// A single cleanup action executed on a repository.
typedef CleanAction = ({String description, bool success, String? error});

/// Full status and cleanup result for a landed PR.
typedef PrCleanResult = ({
  LandedPr pr,
  LocalRepoInfo? localRepo,
  List<String> plannedActions,
  List<CleanAction> executedActions,
  String status,
});

/// Options for configuring `gh-clean`.
class GhCleanOptions {
  final String user;
  final String? repo;
  final int limit;
  final int? lastNDays;
  final bool apply;
  final bool json;
  final bool markdown;
  final String? localRoot;
  final bool skipSync;
  final bool skipWorktrees;
  final bool includeOwned;

  const new({
    this.user = '@me',
    this.repo,
    this.limit = 50,
    this.lastNDays = 7,
    this.apply = false,
    this.json = false,
    this.markdown = false,
    this.localRoot,
    this.skipSync = false,
    this.skipWorktrees = false,
    this.includeOwned = true,
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
      defaultsTo: '7',
      help: 'Filter PRs merged in the last N days (pass 0 for no time limit).',
    )
    ..addFlag(
      'apply',
      negatable: false,
      help: 'Execute worktree pruning, branch deletion, and trunk sync.',
    )
    ..addFlag('json', negatable: false, help: 'Output results in JSON format.')
    ..addFlag(
      'markdown',
      abbr: 'm',
      negatable: false,
      help: 'Output results as GitHub Flavored Markdown.',
    )
    ..addOption(
      'local-root',
      help: 'Base directory for local Git repositories (defaults to ~/github).',
    )
    ..addFlag(
      'skip-sync',
      negatable: false,
      help: 'Skip fast-forwarding default branches against origin.',
    )
    ..addFlag(
      'skip-worktrees',
      negatable: false,
      help: 'Skip pruning matching sibling worktrees.',
    )
    ..addFlag(
      'include-owned',
      defaultsTo: true,
      help: 'Include repositories owned by the user.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );
}

/// Main orchestration logic for `gh-clean`.
Future<void> runGhClean({
  required GhCleanOptions options,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;

  onProgress?.call('Fetching landed pull requests from GitHub...');
  final landedPrs = await fetchLandedPrs(
    user: options.user,
    repo: options.repo,
    lastNDays: options.lastNDays,
    limit: options.limit,
    includeOwned: options.includeOwned,
    processRunner: runner,
  );
  onProgress?.call('Found ${landedPrs.length} landed pull request(s).');

  final rootPath =
      options.localRoot ??
      Platform.environment['GH_LOCAL_ROOT'] ??
      '${Platform.environment['HOME']}/github';
  final rootDir = Directory(rootPath);

  onProgress?.call('Scanning local Git repositories in $rootPath...');
  final localRepos = scanLocalGitRepositories(rootDir, processRunner: runner);
  final repoMap = _buildRepoMap(localRepos);
  onProgress?.call(
    'Indexed ${localRepos.length} local repository checkout(s).',
  );

  final results = [
    for (final pr in landedPrs)
      _processPr(
        pr,
        repoMap[pr.repository.toLowerCase()],
        options: options,
        runner: runner,
        onProgress: onProgress,
      ),
  ];

  _outputReport(results, options);
}

Map<String, LocalRepoInfo> _buildRepoMap(List<LocalRepoInfo> localRepos) {
  final repoMap = <String, LocalRepoInfo>{};
  for (final repo in localRepos) {
    for (final name in repo.repoNames) {
      final key = name.toLowerCase();
      final isRoot = isRootGitRepository(Directory(repo.repoPath));
      final existing = repoMap[key];
      if (existing == null || isRoot) {
        repoMap[key] = repo;
      }
    }
  }
  return repoMap;
}

PrCleanResult _processPr(
  LandedPr pr,
  LocalRepoInfo? localRepo, {
  required GhCleanOptions options,
  required SyncProcessRunner runner,
  void Function(String message)? onProgress,
}) {
  final planned = planCleanup(
    pr,
    localRepo,
    skipSync: options.skipSync,
    skipWorktrees: options.skipWorktrees,
    processRunner: runner,
  );

  var executed = <CleanAction>[];
  var status = 'Pending';

  if (localRepo == null) {
    status = 'Not cloned locally';
  } else if (planned.isEmpty) {
    status = 'Clean (nothing to do)';
  } else if (options.apply) {
    onProgress?.call(
      '[apply] Cleaning ${pr.repository} #${pr.number} (${pr.headRefName})...',
    );
    executed = executeCleanup(
      pr,
      localRepo,
      skipSync: options.skipSync,
      skipWorktrees: options.skipWorktrees,
      processRunner: runner,
      onProgress: onProgress,
    );
    final allSucceeded = executed.every((a) => a.success);
    status = allSucceeded ? 'Applied' : 'Partial Failure';
  }

  return (
    pr: pr,
    localRepo: localRepo,
    plannedActions: planned,
    executedActions: executed,
    status: status,
  );
}

void _outputReport(List<PrCleanResult> results, GhCleanOptions options) {
  if (options.json) {
    print(jsonEncode(formatJsonReport(results, applied: options.apply)));
  } else if (options.markdown) {
    print(formatMarkdownReport(results, applied: options.apply));
  } else {
    printTerminalReport(results, applied: options.apply);
  }
}

/// Builds the GraphQL search query for merged PRs.
String buildLandedSearchQuery({
  required String user,
  String? repo,
  int? lastNDays,
  DateTime? now,
}) {
  final buffer = StringBuffer('is:pr is:merged');
  if (user.isNotEmpty) buffer.write(' author:$user');
  if (repo != null && repo.isNotEmpty) buffer.write(' repo:$repo');

  if (lastNDays != null && lastNDays > 0) {
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
query($q: String!, $limit: Int!) {
  search(query: $q, type: ISSUE, first: $limit) {
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

  final result = runner('gh', [
    'api',
    'graphql',
    '-f',
    'query=$gqlQuery',
    '-F',
    'q=$queryStr',
    '-F',
    'limit=$limit',
  ]);

  if (result.exitCode != 0) {
    throw GhCleanException(
      'GitHub CLI (`gh`) failed with exit code ${result.exitCode}:\n'
      '${result.stderr}',
      exitCode: result.exitCode,
    );
  }

  final stdoutStr = result.stdout as String;
  return _parseGraphQLData(stdoutStr, user: user, includeOwned: includeOwned);
}

List<LandedPr> _parseGraphQLData(
  String stdoutStr, {
  required String user,
  required bool includeOwned,
}) {
  Map<String, dynamic> decoded;
  try {
    decoded = jsonDecode(stdoutStr) as Map<String, dynamic>;
  } catch (e) {
    throw GhCleanException('Failed to parse GitHub GraphQL output: $e');
  }

  if (decoded.containsKey('errors')) {
    final errors = decoded['errors'] as List<dynamic>? ?? [];
    final errorMessages = errors
        .whereType<Map<String, dynamic>>()
        .map((e) => e['message'] as String? ?? 'Unknown GraphQL error')
        .join('\n');
    throw GhCleanException('GraphQL query returned errors:\n$errorMessages');
  }

  final data = decoded['data'] as Map<String, dynamic>?;
  final search = data?['search'] as Map<String, dynamic>?;
  final nodes = search?['nodes'] as List<dynamic>? ?? [];

  return [
    for (final node in nodes.whereType<Map<String, dynamic>>())
      if (parseLandedPrNode(node) case final parsed?)
        if (!isDartSdkRepositoryName(parsed.repository) &&
            _isAllowedUserPr(
              parsed.repository,
              user,
              includeOwned: includeOwned,
            ))
          parsed,
  ];
}

bool _isAllowedUserPr(
  String repository,
  String user, {
  required bool includeOwned,
}) {
  if (includeOwned || user.isEmpty || user == '@me') return true;
  return !repository.toLowerCase().startsWith('${user.toLowerCase()}/');
}

/// Parses a landed PR node from GraphQL.
LandedPr? parseLandedPrNode(Map<String, dynamic> node) {
  final number = node['number'] as int?;
  final title = node['title'] as String?;
  final url = node['url'] as String?;
  final repoMap = node['repository'] as Map<String, dynamic>?;
  final repository = repoMap?['nameWithOwner'] as String? ?? '';

  if (number == null || title == null || url == null || repository.isEmpty) {
    return null;
  }

  final mergedAtStr = node['mergedAt'] as String?;
  final mergedAt = mergedAtStr != null ? DateTime.tryParse(mergedAtStr) : null;

  final closedAtStr = node['closedAt'] as String?;
  final closedAt = closedAtStr != null ? DateTime.tryParse(closedAtStr) : null;

  final mergeCommit = node['mergeCommit'] as Map<String, dynamic>?;
  final mergeSha = mergeCommit?['oid'] as String?;

  return (
    number: number,
    title: title,
    url: url,
    repository: repository,
    repoUrl: repoMap?['url'] as String? ?? '',
    headRefName: node['headRefName'] as String? ?? '',
    headRefOid: node['headRefOid'] as String? ?? '',
    baseRefName: node['baseRefName'] as String? ?? 'main',
    mergeSha: mergeSha,
    mergedAt: mergedAt,
    closedAt: closedAt,
  );
}

bool _isTrunkSynced(LocalRepoInfo localRepo, String trunkBranch) {
  final trunk = localRepo.branches
      .where((b) => b.name == trunkBranch)
      .firstOrNull;
  return trunk != null && trunk.isUpToDateWithUpstream;
}

/// Identifies candidate cleanup actions without performing mutations.
List<String> planCleanup(
  LandedPr pr,
  LocalRepoInfo? localRepo, {
  bool skipSync = false,
  bool skipWorktrees = false,
  SyncProcessRunner? processRunner,
}) {
  if (localRepo == null) return const [];
  final runner = processRunner ?? defaultSyncProcessRunner;
  final actions = <String>[];

  final headBranch = pr.headRefName;
  final trunkBranch = _resolveTrunkBranch(pr, localRepo);
  final repoShortName = pr.repository.split('/').last;

  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt != null && !skipWorktrees) {
    if (_isDirDirty(matchingWt.path, runner)) {
      actions.add(
        'Skip worktree at ${matchingWt.path} (has uncommitted changes)',
      );
    } else {
      actions.add('Prune worktree at ${matchingWt.path}');
    }
  }

  if (localRepo.currentBranch == headBranch && headBranch.isNotEmpty) {
    actions.add('Switch branch: `$headBranch` -> `$trunkBranch`');
  }

  if (headBranch.isNotEmpty &&
      headBranch != trunkBranch &&
      !_isProtectedBranch(headBranch) &&
      localRepo.branches.any((b) => b.name == headBranch)) {
    actions.add('Delete local branch `$headBranch`');
  }

  if (!skipSync && !_isTrunkSynced(localRepo, trunkBranch)) {
    actions.add('Sync `$trunkBranch` to `origin/$trunkBranch`');
  }

  return actions;
}

/// Executes worktree pruning, branch deletion, and default branch sync.
List<CleanAction> executeCleanup(
  LandedPr pr,
  LocalRepoInfo localRepo, {
  bool skipSync = false,
  bool skipWorktrees = false,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final actions = <CleanAction>[];
  final headBranch = pr.headRefName;
  final trunkBranch = _resolveTrunkBranch(pr, localRepo);
  final repoShortName = pr.repository.split('/').last;

  if (!skipWorktrees) {
    final wtAction = _executeWorktreePrune(
      localRepo,
      headBranch,
      repoShortName,
      runner,
    );
    if (wtAction != null) {
      actions.add(wtAction);
      onProgress?.call(
        '  ${wtAction.success ? "✓" : "✗"} ${wtAction.description}',
      );
    }
  }

  final checkoutAction = _executeBranchCheckout(
    localRepo,
    headBranch,
    trunkBranch,
    runner,
  );
  if (checkoutAction != null) {
    actions.add(checkoutAction);
    onProgress?.call(
      '  ${checkoutAction.success ? "✓" : "✗"} ${checkoutAction.description}',
    );
  }

  final deleteAction = _executeBranchDeletion(
    localRepo,
    headBranch,
    trunkBranch,
    pr.headRefOid,
    runner,
  );
  if (deleteAction != null) {
    actions.add(deleteAction);
    onProgress?.call(
      '  ${deleteAction.success ? "✓" : "✗"} ${deleteAction.description}',
    );
  }

  if (!skipSync) {
    final syncAction = _executeTrunkSync(
      localRepo,
      headBranch,
      trunkBranch,
      runner,
    );
    actions.add(syncAction);
    onProgress?.call(
      '  ${syncAction.success ? "✓" : "✗"} ${syncAction.description}',
    );
  }

  return actions;
}

String _resolveTrunkBranch(LandedPr pr, LocalRepoInfo? localRepo) {
  if (_isProtectedBranch(pr.baseRefName)) {
    return pr.baseRefName;
  }
  if (localRepo != null) {
    for (final candidate in _trunkCandidates) {
      if (localRepo.branches.any((b) => b.name == candidate)) {
        return candidate;
      }
    }
  }
  return 'main';
}

const _trunkCandidates = ['main', 'master', 'trunk', 'dev'];

CleanAction? _executeWorktreePrune(
  LocalRepoInfo localRepo,
  String headBranch,
  String repoShortName,
  SyncProcessRunner runner,
) {
  final matchingWt = findMatchingWorktree(localRepo, headBranch, repoShortName);
  if (matchingWt == null) return null;

  if (_isDirDirty(matchingWt.path, runner)) {
    return (
      description: 'Pruning worktree at ${matchingWt.path}',
      success: false,
      error: 'Worktree has uncommitted changes (dirty).',
    );
  }

  final res = runner('git', [
    '-C',
    localRepo.repoPath,
    'worktree',
    'remove',
    matchingWt.path,
  ]);

  return res.exitCode == 0
      ? (
          description: 'Pruned sibling worktree at ${matchingWt.path}',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to prune worktree at ${matchingWt.path}',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

CleanAction? _executeBranchCheckout(
  LocalRepoInfo localRepo,
  String headBranch,
  String baseBranch,
  SyncProcessRunner runner,
) {
  if (localRepo.currentBranch != headBranch || headBranch.isEmpty) return null;

  final res = runner('git', ['-C', localRepo.repoPath, 'checkout', baseBranch]);
  return res.exitCode == 0
      ? (
          description: 'Switched from `$headBranch` to `$baseBranch`',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to checkout `$baseBranch`',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

CleanAction? _executeBranchDeletion(
  LocalRepoInfo localRepo,
  String headBranch,
  String trunkBranch,
  String? headRefOid,
  SyncProcessRunner runner,
) {
  if (headBranch.isEmpty ||
      headBranch == trunkBranch ||
      _isProtectedBranch(headBranch) ||
      !localRepo.branches.any((b) => b.name == headBranch)) {
    return null;
  }

  if (headRefOid != null && headRefOid.isNotEmpty) {
    final logRes = runner('git', [
      '-C',
      localRepo.repoPath,
      'log',
      '$headRefOid..$headBranch',
      '--oneline',
    ]);
    if (logRes.exitCode == 0 && (logRes.stdout as String).trim().isNotEmpty) {
      return (
        description: 'Delete local branch `$headBranch`',
        success: false,
        error: 'Branch has unpushed commits past PR HEAD ($headRefOid).',
      );
    }
  }

  final res = runner('git', [
    '-C',
    localRepo.repoPath,
    'branch',
    '-D',
    headBranch,
  ]);
  return res.exitCode == 0
      ? (
          description: 'Deleted local feature branch `$headBranch`',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to delete local branch `$headBranch`',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

CleanAction _executeTrunkSync(
  LocalRepoInfo localRepo,
  String headBranch,
  String trunkBranch,
  SyncProcessRunner runner,
) {
  final repoPath = localRepo.repoPath;
  final currentResult = runner('git', [
    'branch',
    '--show-current',
  ], workingDirectory: repoPath);
  final currentBranch = currentResult.exitCode == 0
      ? (currentResult.stdout as String).trim()
      : localRepo.currentBranch;
  final isOnTrunk = currentBranch == trunkBranch;

  if (isOnTrunk) {
    runner('git', ['-C', repoPath, 'fetch', 'origin']);
    final res = runner('git', [
      '-C',
      repoPath,
      'merge',
      '--ff-only',
      'origin/$trunkBranch',
    ]);
    return res.exitCode == 0
        ? (
            description: 'Synced `$trunkBranch` to `origin/$trunkBranch`',
            success: true,
            error: null,
          )
        : (
            description: 'Failed to fast-forward `$trunkBranch`',
            success: false,
            error: (res.stderr as String).trim(),
          );
  }

  final res = runner('git', [
    '-C',
    repoPath,
    'fetch',
    'origin',
    '$trunkBranch:$trunkBranch',
  ]);
  return res.exitCode == 0
      ? (
          description: 'Synced `$trunkBranch` to `origin/$trunkBranch`',
          success: true,
          error: null,
        )
      : (
          description: 'Failed to fetch `$trunkBranch`',
          success: false,
          error: (res.stderr as String).trim(),
        );
}

/// Discovers an attached worktree matching the PR branch or folder naming
/// scheme.
LocalWorktreeEntry? findMatchingWorktree(
  LocalRepoInfo localRepo,
  String branchName,
  String repoShortName,
) {
  if (branchName.isEmpty) return null;

  for (final wt in localRepo.worktrees) {
    if (wt.path == localRepo.repoPath) continue;
    if (wt.branch == branchName || wt.branch == 'refs/heads/$branchName') {
      return wt;
    }
    final folder = p.basename(wt.path);
    if (folder == '_$repoShortName-$branchName' ||
        folder == '_${repoShortName}_$branchName') {
      return wt;
    }
  }
  return null;
}

bool _isDirDirty(String path, SyncProcessRunner runner) =>
    isRepoDirtySync(path, processRunner: runner);

bool _isProtectedBranch(String branch) {
  final lower = branch.toLowerCase().trim();
  if (lower.startsWith('release/') || lower.startsWith('release-')) {
    return true;
  }
  const protected = {'main', 'master', 'trunk', 'dev', 'release', 'head'};
  return protected.contains(lower);
}

/// Formats output as GitHub Flavored Markdown.
///
/// Rows are sorted by `org` -> `repo` -> `oldest PR number`.
/// Actionable PRs (requiring worktree pruning or branch deletion) are rendered
/// as individual rows with their specific PR link and actions. PRs with no
/// local branch/worktree mutations are clustered into a single summary row
/// per repository.
String formatMarkdownReport(
  List<PrCleanResult> results, {
  required bool applied,
}) {
  final buffer = StringBuffer()
    ..writeln('# Landed Pull Requests Cleanup Report')
    ..writeln()
    ..writeln(
      applied
          ? '**Mode**: 🚀 Applied Cleanup'
          : '**Mode**: 🔍 Preview Mode (Dry Run)',
    )
    ..writeln();

  if (results.isEmpty) {
    buffer.writeln('No recently landed pull requests found.');
    return buffer.toString();
  }

  buffer
    ..writeln('<!-- mdformat off -->')
    ..writeln('| Repository | PR(s) | Local Directory | Actions / Status |')
    ..writeln('| :--- | :--- | :--- | :--- |');

  final rows = _buildSortedReportRows(results, applied: applied);
  for (final row in rows) {
    buffer.writeln(row.markdown);
  }

  buffer.writeln('<!-- mdformat on -->');
  return buffer.toString();
}

List<_ReportRow> _buildSortedReportRows(
  List<PrCleanResult> results, {
  required bool applied,
}) {
  final repoMap = <String, List<PrCleanResult>>{};
  for (final r in results) {
    repoMap.putIfAbsent(r.pr.repository, () => []).add(r);
  }

  final rows = <_ReportRow>[];

  for (final entry in repoMap.entries) {
    final list = entry.value;
    final parts = entry.key.split('/');
    final org = parts.isNotEmpty ? parts[0] : '';
    final repo = parts.length > 1 ? parts[1] : '';

    final actionable = list.where(_hasLocalBranchOrWorktreeAction).toList()
      ..sort((a, b) => a.pr.number.compareTo(b.pr.number));
    final noOps =
        list.where((r) => !_hasLocalBranchOrWorktreeAction(r)).toList()
          ..sort((a, b) => a.pr.number.compareTo(b.pr.number));

    for (final r in actionable) {
      rows.add((
        org: org,
        repo: repo,
        minPrNumber: r.pr.number,
        markdown: _formatActionableMarkdownRow(r, applied: applied),
      ));
    }

    if (noOps.isNotEmpty) {
      rows.add((
        org: org,
        repo: repo,
        minPrNumber: noOps.first.pr.number,
        markdown: _formatNoOpClusterMarkdownRow(noOps, applied: applied),
      ));
    }
  }

  rows.sort((a, b) {
    final orgCmp = a.org.toLowerCase().compareTo(b.org.toLowerCase());
    if (orgCmp != 0) return orgCmp;
    final repoCmp = a.repo.toLowerCase().compareTo(b.repo.toLowerCase());
    if (repoCmp != 0) return repoCmp;
    return a.minPrNumber.compareTo(b.minPrNumber);
  });

  return rows;
}

typedef _ReportRow = ({
  String org,
  String repo,
  int minPrNumber,
  String markdown,
});

bool _hasLocalBranchOrWorktreeAction(PrCleanResult r) {
  if (r.localRepo == null) return false;
  return r.plannedActions.any(
        (a) =>
            a.startsWith('Prune worktree') ||
            a.startsWith('Delete local branch'),
      ) ||
      r.executedActions.any(
        (a) =>
            a.description.contains('worktree') ||
            a.description.contains('branch'),
      );
}

String _formatActionableMarkdownRow(PrCleanResult r, {required bool applied}) {
  final pr = r.pr;
  final repoLink = '[**${pr.repository}**](${pr.repoUrl})';
  final prLink = '[#${pr.number}](${pr.url})';
  final localDir = r.localRepo != null
      ? '[`${r.localRepo!.repoPath}`](file://${r.localRepo!.repoPath})'
      : '_Not cloned_';

  String statusDetail;
  if (applied) {
    statusDetail = r.executedActions
        .map((a) => '${a.success ? "✅" : "❌"} ${a.description}')
        .join('<br>');
  } else {
    statusDetail = r.plannedActions.map((a) => '• $a').join('<br>');
  }

  return '| $repoLink | $prLink | $localDir | $statusDetail |';
}

String _formatNoOpClusterMarkdownRow(
  List<PrCleanResult> list, {
  required bool applied,
}) {
  final first = list.first;
  final repoLink = '[**${first.pr.repository}**](${first.pr.repoUrl})';
  final prLinks = list.map((r) => '[#${r.pr.number}](${r.pr.url})').join(', ');
  final prLabel = list.length == 1
      ? '[#${first.pr.number}](${first.pr.url})'
      : '${list.length} PRs: $prLinks';

  final localDir = first.localRepo != null
      ? '[`${first.localRepo!.repoPath}`](file://${first.localRepo!.repoPath})'
      : '_Not cloned_';

  String statusDetail;
  if (first.localRepo == null) {
    statusDetail = '_Not cloned locally_';
  } else if (applied) {
    statusDetail = '✅ Up to date (no local branches)';
  } else {
    final hasPendingSync = list.any(
      (r) => r.plannedActions.any((a) => a.startsWith('Sync ')),
    );
    if (hasPendingSync) {
      statusDetail = '• Sync `main` to `origin/main` (no local branches)';
    } else {
      statusDetail = '✅ Up to date (no local branches)';
    }
  }

  return '| $repoLink | $prLabel | $localDir | $statusDetail |';
}

/// Formats output for terminal viewing.
void printTerminalReport(List<PrCleanResult> results, {required bool applied}) {
  final modeStr = applied
      ? green.wrap('🚀 Applied Cleanup')!
      : cyan.wrap('🔍 Preview Mode (Dry Run)')!;
  print('${styleBold.wrap("Landed PR Cleanup")} [$modeStr]\n');

  if (results.isEmpty) {
    print(styleDim.wrap('No recently landed pull requests found.')!);
    return;
  }

  for (final r in results) {
    _printTerminalPrHeader(r);
    if (applied) {
      _printExecutedActions(r.executedActions);
    } else {
      _printPlannedActions(r.plannedActions, r.status);
    }
    print('');
  }
}

void _printTerminalPrHeader(PrCleanResult r) {
  final pr = r.pr;
  print('${styleBold.wrap("${pr.repository} #${pr.number}")}: ${pr.title}');
  print('  URL:    ${pr.url}');
  print('  Branch: ${pr.headRefName} -> ${pr.baseRefName}');
  if (r.localRepo != null) {
    print('  Local:  ${r.localRepo!.repoPath}');
  }
}

void _printExecutedActions(List<CleanAction> actions) {
  for (final act in actions) {
    final icon = act.success ? green.wrap('✅') : red.wrap('❌');
    print('  $icon ${act.description}');
    if (act.error != null) {
      print('     ${red.wrap("Error: ${act.error}")}');
    }
  }
}

void _printPlannedActions(List<String> plannedActions, String status) {
  if (plannedActions.isEmpty) {
    final statusColor = status == 'Not cloned locally'
        ? styleDim
        : status.contains('Failure')
        ? red
        : yellow;
    print('  Status: ${statusColor.wrap(status)}');
    return;
  }

  print('  Planned Actions:');
  for (final plan in plannedActions) {
    print('    • $plan');
  }
}

/// Formats output as machine-readable JSON.
Map<String, dynamic> formatJsonReport(
  List<PrCleanResult> results, {
  required bool applied,
}) => {
  'applied': applied,
  'total': results.length,
  'results': results
      .map(
        (r) => {
          'pr': {
            'number': r.pr.number,
            'title': r.pr.title,
            'url': r.pr.url,
            'repository': r.pr.repository,
            'headRefName': r.pr.headRefName,
            'baseRefName': r.pr.baseRefName,
            'mergedAt': r.pr.mergedAt?.toIso8601String(),
          },
          'localRepo': r.localRepo != null
              ? {
                  'repoName': r.localRepo!.repoName,
                  'repoPath': r.localRepo!.repoPath,
                  'currentBranch': r.localRepo!.currentBranch,
                }
              : null,
          'status': r.status,
          'plannedActions': r.plannedActions,
          'executedActions': r.executedActions
              .map(
                (a) => {
                  'description': a.description,
                  'success': a.success,
                  'error': a.error,
                },
              )
              .toList(),
        },
      )
      .toList(),
};
