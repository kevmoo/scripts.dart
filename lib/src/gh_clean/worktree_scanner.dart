import 'dart:convert';
import 'dart:io';

import '../local_repo_scanner.dart';
import '../process_utils.dart';
import 'models.dart';

typedef _CandidateWorktree = ({
  LocalRepoInfo repo,
  LocalWorktreeEntry wt,
  String owner,
  String name,
});

/// Discovers worktrees across [localRepos] that have no matching PR on GitHub.
///
/// [matchedWorktreePaths] is the set of worktree paths that were matched to
/// landed PRs and are already being handled.
Future<List<UnlinkedWorktree>> findUnlinkedWorktrees(
  List<LocalRepoInfo> localRepos,
  Set<String> matchedWorktreePaths, {
  String? repoFilter,
  SyncProcessRunner? processRunner,
  void Function(String message)? onProgress,
}) async {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final candidates = _collectCandidateWorktrees(
    localRepos,
    matchedWorktreePaths,
    repoFilter: repoFilter,
  );

  final unlinkedCandidates = [
    ...candidates.detachedCandidates,
    ..._filterUnlinkedCandidates(candidates.branchCandidates, runner),
  ];

  return [
    for (final item in unlinkedCandidates)
      _populateUnlinkedWorktreeDetails(item, runner),
  ]..sort((a, b) {
    final repoCmp = a.repository.toLowerCase().compareTo(
      b.repository.toLowerCase(),
    );
    if (repoCmp != 0) return repoCmp;
    return a.worktreePath.toLowerCase().compareTo(b.worktreePath.toLowerCase());
  });
}

({
  List<_CandidateWorktree> branchCandidates,
  List<({LocalRepoInfo repo, LocalWorktreeEntry wt})> detachedCandidates,
})
_collectCandidateWorktrees(
  List<LocalRepoInfo> localRepos,
  Set<String> matchedWorktreePaths, {
  String? repoFilter,
}) {
  final candidates = <_CandidateWorktree>[];
  final detachedCandidates = <({LocalRepoInfo repo, LocalWorktreeEntry wt})>[];

  for (final r in filteredRootRepos(localRepos, repoFilter: repoFilter)) {
    _classifyRepoWorktrees(
      r.repo,
      r.owner,
      r.name,
      matchedWorktreePaths,
      candidates,
      detachedCandidates,
    );
  }

  return (branchCandidates: candidates, detachedCandidates: detachedCandidates);
}

void _classifyRepoWorktrees(
  LocalRepoInfo repo,
  String owner,
  String name,
  Set<String> matchedWorktreePaths,
  List<_CandidateWorktree> candidates,
  List<({LocalRepoInfo repo, LocalWorktreeEntry wt})> detachedCandidates,
) {
  for (final wt in repo.worktrees) {
    if (!_isCandidateWorktree(wt, repo.repoPath, matchedWorktreePaths)) {
      continue;
    }

    if (wt.branch.isEmpty || wt.branch == 'DETACHED') {
      detachedCandidates.add((repo: repo, wt: wt));
    } else {
      candidates.add((repo: repo, wt: wt, owner: owner, name: name));
    }
  }
}

bool _isCandidateWorktree(
  LocalWorktreeEntry wt,
  String repoPath,
  Set<String> matchedWorktreePaths,
) {
  if (wt.path == repoPath) return false;
  if (matchedWorktreePaths.contains(wt.path)) return false;
  return Directory(wt.path).existsSync();
}

List<({LocalRepoInfo repo, LocalWorktreeEntry wt})> _filterUnlinkedCandidates(
  List<_CandidateWorktree> candidates,
  SyncProcessRunner runner,
) {
  if (candidates.isEmpty) return const [];
  final unlinked = <({LocalRepoInfo repo, LocalWorktreeEntry wt})>[];
  const batchSize = 30;

  for (var i = 0; i < candidates.length; i += batchSize) {
    final batch = candidates.skip(i).take(batchSize).toList();
    final queryStr = _buildBatchWorktreePrQuery(batch);
    final result = runner('gh', ['api', 'graphql', '-f', 'query=$queryStr']);
    if (result.exitCode != 0) {
      stderr.writeln(
        'Warning: Failed to fetch GraphQL PR data for candidate worktrees: '
        '${result.stderr.toString().trim()}',
      );
      continue;
    }

    final data = tryParseGraphQLData(result.stdout);
    if (data == null) {
      stderr.writeln(
        'Warning: Could not parse GraphQL response for candidate worktrees.',
      );
      continue;
    }

    for (var b = 0; b < batch.length; b++) {
      if (!_batchItemHasPr(data, b)) {
        unlinked.add((repo: batch[b].repo, wt: batch[b].wt));
      }
    }
  }

  return unlinked;
}

bool _batchItemHasPr(Map<String, dynamic>? data, int index) {
  final qVal = data?['q$index'];
  final qMap = qVal is Map<String, dynamic> ? qVal : null;
  final prsVal = qMap?['pullRequests'];
  final prsMap = prsVal is Map<String, dynamic> ? prsVal : null;
  final prNodes = (prsMap?['nodes'] as List<dynamic>?) ?? [];
  return prNodes.isNotEmpty;
}

String _buildBatchWorktreePrQuery(List<_CandidateWorktree> batch) {
  final queryBuffer = StringBuffer('query {\n');
  for (var b = 0; b < batch.length; b++) {
    final item = batch[b];
    final encOwner = jsonEncode(item.owner);
    final encName = jsonEncode(item.name);
    final encBranch = jsonEncode(item.wt.branch);
    queryBuffer.writeln(
      '  q$b: repository(owner: $encOwner, name: $encName) {\n'
      '    pullRequests(headRefName: $encBranch, first: 1) {\n'
      '      nodes {\n'
      '        number\n'
      '        state\n'
      '      }\n'
      '    }\n'
      '  }',
    );
  }
  queryBuffer.writeln('}');
  return queryBuffer.toString();
}

UnlinkedWorktree _populateUnlinkedWorktreeDetails(
  ({LocalRepoInfo repo, LocalWorktreeEntry wt}) item,
  SyncProcessRunner runner,
) {
  final repo = item.repo;
  final wt = item.wt;
  final trunk = resolveTrunkBranch(repo);
  final commitsAhead = _countCommitsAhead(wt.path, trunk, runner);
  final lastCommit = _getLastCommitInfo(wt.path, runner);

  return (
    repository: repo.repoName,
    worktreePath: wt.path,
    branch: wt.branch.isEmpty ? '(detached)' : wt.branch,
    sha: wt.sha,
    commitsAhead: commitsAhead,
    lastCommitDate: lastCommit.date,
    lastCommitSubject: lastCommit.subject,
  );
}

int? _countCommitsAhead(
  String worktreePath,
  String trunkBranch,
  SyncProcessRunner runner,
) {
  final refs = ['origin/$trunkBranch', 'upstream/$trunkBranch', trunkBranch];
  for (final ref in refs) {
    final revResult = runner('git', [
      'rev-list',
      '--count',
      '$ref..HEAD',
    ], workingDirectory: worktreePath);
    if (revResult.exitCode == 0) {
      final parsed = int.tryParse((revResult.stdout as String).trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

({String? date, String? subject}) _getLastCommitInfo(
  String worktreePath,
  SyncProcessRunner runner,
) {
  final logResult = runner('git', [
    'log',
    '-1',
    '--format=%cs|%s',
  ], workingDirectory: worktreePath);
  if (logResult.exitCode != 0) return (date: null, subject: null);
  final out = (logResult.stdout as String).trim();
  if (out.isEmpty) return (date: null, subject: null);

  final parts = out.split('|');
  final date = parts[0].trim();
  final subject = parts.length > 1 ? parts.sublist(1).join('|').trim() : null;
  return (date: date, subject: subject);
}
