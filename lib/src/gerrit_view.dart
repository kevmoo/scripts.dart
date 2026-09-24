import 'dart:convert';
import 'dart:io';

import 'package:io/ansi.dart';
import 'package:io/io.dart';

import 'gerrit_view/report_printer.dart';
import 'git_extensions.dart';
import 'shared/gh_args.dart';

export 'gerrit_view/report_printer.dart';

/// Exception thrown by Gerrit View tool operations.
class GerritViewException extends CliException {
  const new(super.message, {super.exitCode = 1});
}

typedef CommitDetails = ({
  String sha,
  String relativeDate,
  String changeId,
  String rawBody,
});

typedef ThreadSummary = ({
  int totalThreads,
  int unresolvedReviewerLeaves,
  int unresolvedAuthorLeaves,
});

typedef RemoteCL = ({
  int number,
  String changeId,
  String subject,
  String status,
  String currentRevision,
  int currentRevisionNumber,
  String lastAuthorTouch,
  List<String> reviewers,
  List<String> crVotes,
  String cqStatus,
  ThreadSummary threads,
  String nextAction,
});

enum AlignmentState { inSync, contentIdentical, diverged }

typedef AlignmentResult = ({AlignmentState state, String display});

enum ClStatus {
  newCl('NEW'),
  merged('MERGED'),
  abandoned('ABANDONED'),
  unknown('UNKNOWN');

  final String value;
  new(this.value);
  static ClStatus parse(String raw) {
    final normalized = raw.toUpperCase();
    return ClStatus.values.firstWhere(
      (s) => s.value == normalized,
      orElse: () => ClStatus.unknown,
    );
  }
}

typedef _BranchAnalysis = ({
  Map<String, (RemoteCL, CommitDetails, AlignmentResult)> alignedBranches,
  Map<String, (int, CommitDetails, ClStatus)> closedClBranches,
  Map<int, List<String>> conflatedBranches,
  Map<String, (RemoteCL, CommitDetails)> mismatchedChangeIdBranches,
  Map<int, RemoteCL> remoteOnlyCLs,
});

typedef CleanupSafety = ({bool isSafe, List<String> unmergedShas});

AlignmentResult calculateAlignment(
  String repoPath,
  String branchName,
  CommitDetails local,
  RemoteCL remote,
) {
  if (local.sha == remote.currentRevision) {
    return (
      state: AlignmentState.inSync,
      display: green.wrap(
        '✅ IN SYNC (Commit perfectly matches Gerrit latest)',
      )!,
    );
  }

  final remoteTreeResult = Process.runSync('git', [
    'rev-parse',
    '--verify',
    '--quiet',
    '${remote.currentRevision}^{tree}',
  ], workingDirectory: repoPath);

  if (remoteTreeResult.exitCode != 0) {
    return (
      state: AlignmentState.diverged,
      display: yellow.wrap(
        '⚠️ DIVERGED (Commit differs; shadow fetch failed)',
      )!,
    );
  }

  final localTreeResult = Process.runSync('git', [
    'rev-parse',
    '$branchName^{tree}',
  ], workingDirectory: repoPath);

  if (localTreeResult.exitCode == 0) {
    final remoteTree = (remoteTreeResult.stdout as String).trim();
    final localTree = (localTreeResult.stdout as String).trim();

    if (remoteTree == localTree) {
      return (
        state: AlignmentState.contentIdentical,
        display: green.wrap(
          '✅ CONTENT IDENTICAL (Commits differ, but file content matches '
          'Gerrit)',
        )!,
      );
    }
  }

  return (
    state: AlignmentState.diverged,
    display: yellow.wrap(
      '⚠️ DIVERGED (Commits and file contents both differ from Gerrit)',
    )!,
  );
}

CleanupSafety checkCleanupSafety(
  String repoPath,
  String branchName,
  String defaultBranch,
) {
  final result = Process.runSync('git', [
    'cherry',
    'origin/$defaultBranch',
    branchName,
  ], workingDirectory: repoPath);

  if (result.exitCode != 0) {
    return (isSafe: false, unmergedShas: <String>[]);
  }

  final output = (result.stdout as String).trim();
  if (output.isEmpty) {
    return (isSafe: true, unmergedShas: <String>[]);
  }

  final unmerged = <String>[
    for (final line in output.split('\n'))
      if (line.startsWith('+ ')) line.substring(2).trim(),
  ];

  return (isSafe: unmerged.isEmpty, unmergedShas: unmerged);
}

String _getDefaultBranch(String repoPath) => sniffDefaultBranchSync(repoPath);

String? _getCurrentBranch(String repoPath) {
  final result = Process.runSync('git', [
    'rev-parse',
    '--abbrev-ref',
    'HEAD',
  ], workingDirectory: repoPath);

  if (result.exitCode == 0) {
    final output = (result.stdout as String).trim();
    if (output.isNotEmpty && output != 'HEAD') {
      return output;
    }
  }
  return null;
}

Map<String, String> getWorktreeBranches(String repoPath) {
  final result = Process.runSync('git', [
    'worktree',
    'list',
    '--porcelain',
  ], workingDirectory: repoPath);

  if (result.exitCode != 0) return {};

  final worktrees = <String, String>{};
  String? currentWorktree;

  for (final line in (result.stdout as String).split('\n')) {
    if (line.startsWith('worktree ')) {
      currentWorktree = line.substring('worktree '.length).trim();
    } else if (line.startsWith('branch refs/heads/')) {
      final branch = line.substring('branch refs/heads/'.length).trim();
      if (currentWorktree != null) {
        worktrees[branch] = currentWorktree;
      }
    } else if (line.isEmpty) {
      currentWorktree = null;
    }
  }

  return worktrees;
}

String _resolveRepoInfo(String? gerritRepo) {
  final repoPath = gerritRepo == null
      ? Directory.current.absolute.path
      : Directory(gerritRepo).absolute.path;
  final candidates = <String>[repoPath, '$repoPath/core/main/sdk'];
  for (final candidate in candidates) {
    if (!Directory(candidate).existsSync()) continue;
    final checkResult = Process.runSync('git', [
      'rev-parse',
      '--show-toplevel',
    ], workingDirectory: candidate);
    if (checkResult.exitCode == 0) {
      return (checkResult.stdout as String).trim();
    }
  }
  throw GerritViewException(
    'Directory "$repoPath" is not a Git repository (or git is missing).',
    exitCode: ExitCode.config.code,
  );
}

String? _getGitConfig(String key, String repoPath) {
  final result = Process.runSync('git', [
    'config',
    '--get',
    key,
  ], workingDirectory: repoPath);
  if (result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty) {
    return (result.stdout as String).trim();
  }
  return null;
}

String _resolveGerritRemoteName(String actualRepoRoot) {
  for (final remote in const ['upstream', 'dart-googlesource', 'origin']) {
    final url = _getGitConfig('remote.$remote.url', actualRepoRoot);
    if (url != null &&
        (url.contains('googlesource.com') ||
            url.startsWith('sso://') ||
            url.contains('review.chrome'))) {
      return remote;
    }
  }
  return 'origin';
}

String? _parseGerritHostFromConfig(String actualRepoRoot) {
  final serverResult = Process.runSync('git', [
    'config',
    '--get-regexp',
    r'branch\..*\.gerritserver',
  ], workingDirectory: actualRepoRoot);
  if (serverResult.exitCode != 0) return null;

  for (final line in (serverResult.stdout as String).trim().split('\n')) {
    final lastSpace = line.lastIndexOf(' ');
    if (lastSpace == -1) continue;
    final uri = Uri.tryParse(line.substring(lastSpace + 1).trim());
    if (uri != null && uri.host.isNotEmpty) return uri.host;
  }
  return null;
}

(String, String?)? _parseRemoteOrigin(String actualRepoRoot) {
  final remoteName = _resolveGerritRemoteName(actualRepoRoot);
  final remoteUrl = _getGitConfig('remote.$remoteName.url', actualRepoRoot);
  if (remoteUrl == null) return null;
  if (remoteUrl.startsWith('sso://')) {
    final parts = remoteUrl.substring('sso://'.length).split('/');
    if (parts.length >= 2) {
      final host = '${parts.first}-review.googlesource.com';
      final lastSeg = parts.last;
      final gProject = lastSeg.endsWith('.git')
          ? lastSeg.substring(0, lastSeg.length - 4)
          : lastSeg;
      return (host, gProject);
    }
  }
  if (!remoteUrl.contains('googlesource.com') &&
      !remoteUrl.contains('review.chrome')) {
    return null;
  }
  final uri = Uri.tryParse(remoteUrl);
  if (uri == null || uri.host.isEmpty) return null;

  String? gProject;
  if (uri.pathSegments.isNotEmpty) {
    final lastSeg = uri.pathSegments.last;
    gProject = lastSeg.endsWith('.git')
        ? lastSeg.substring(0, lastSeg.length - 4)
        : lastSeg;
  }
  return (uri.host, gProject);
}

(String, String, bool) _resolveGerritDetails(String actualRepoRoot) {
  var isGerrit = _getGitConfig('gerrit.host', actualRepoRoot) != null;
  var gerritHost = _getGitConfig('gerrit.host', actualRepoRoot);
  if (gerritHost != null && gerritHost.toLowerCase() == 'true') {
    gerritHost = null;
  }
  var gerritProject = _getGitConfig('gerrit.project', actualRepoRoot);

  gerritHost ??= _parseGerritHostFromConfig(actualRepoRoot);
  if (gerritHost == null || gerritProject == null) {
    final origin = _parseRemoteOrigin(actualRepoRoot);
    if (origin != null) {
      isGerrit = true;
      gerritHost ??= origin.$1;
      gerritProject ??= origin.$2;
    }
  }

  if (!isGerrit) {
    throw GerritViewException(
      'Directory "$actualRepoRoot" is not a Gerrit repository.\n'
      'Neither "gerrit.host" is configured nor is the remote origin '
      'hosted on a Gerrit server.',
      exitCode: ExitCode.config.code,
    );
  }

  gerritHost ??= 'dart-review.googlesource.com';
  if (gerritHost.endsWith('.googlesource.com') &&
      !gerritHost.endsWith('-review.googlesource.com')) {
    gerritHost = gerritHost.replaceFirst(
      '.googlesource.com',
      '-review.googlesource.com',
    );
  }
  gerritProject ??= 'sdk';
  return (gerritHost, gerritProject, isGerrit);
}

String _findRootCommentId(String id, Map<String, String> parentById) {
  var current = id;
  final visited = <String>{current};
  while (true) {
    final parent = parentById[current];
    if (parent == null || parent.isEmpty || !visited.add(parent)) break;
    current = parent;
  }
  return current;
}

Map<String, List<Map<String, dynamic>>> _groupCommentsByRoot(
  Map<String, dynamic> commentsByFile,
) {
  final allComments = <Map<String, dynamic>>[];
  final parentById = <String, String>{};

  for (final fileList in commentsByFile.values) {
    if (fileList is! List) continue;
    for (final item in fileList) {
      if (item is! Map<String, dynamic>) continue;
      allComments.add(item);
      final id = item['id'] as String? ?? '';
      final parentId = item['in_reply_to'] as String? ?? '';
      if (id.isNotEmpty && parentId.isNotEmpty) {
        parentById[id] = parentId;
      }
    }
  }

  final threadsByRoot = <String, List<Map<String, dynamic>>>{};
  for (var i = 0; i < allComments.length; i++) {
    final comment = allComments[i];
    final id = comment['id'] as String? ?? 'anon_$i';
    final rootId = _findRootCommentId(id, parentById);
    (threadsByRoot[rootId] ??= []).add(comment);
  }
  return threadsByRoot;
}

/// Reconstructs Gerrit `in_reply_to` comment trees by root ancestor ID and
/// evaluates the latest comment in each root thread so sibling replies and
/// resolved parent comments match Gerrit's native unresolved thread state.
ThreadSummary parseGerritCommentsJson(
  Map<String, dynamic> commentsByFile,
  int? ownerId,
) {
  final threadsByRoot = _groupCommentsByRoot(commentsByFile);

  var unresolvedReviewerLeaves = 0;
  var unresolvedAuthorLeaves = 0;

  for (final thread in threadsByRoot.values) {
    thread.sort(
      (a, b) => (a['updated'] as String? ?? '').compareTo(
        b['updated'] as String? ?? '',
      ),
    );
    final latest = thread.last;
    if (latest['unresolved'] != true) continue;

    final authorMap = latest['author'] as Map<String, dynamic>?;
    final authorId = authorMap?['_account_id'] as int?;
    if (ownerId != null && authorId == ownerId) {
      unresolvedAuthorLeaves++;
    } else {
      unresolvedReviewerLeaves++;
    }
  }

  return (
    totalThreads: threadsByRoot.length,
    unresolvedReviewerLeaves: unresolvedReviewerLeaves,
    unresolvedAuthorLeaves: unresolvedAuthorLeaves,
  );
}

String computeGerritNextAction({
  required List<String> reviewers,
  required List<String> crVotes,
  required String cqStatus,
  required ThreadSummary threads,
}) {
  if (threads.unresolvedReviewerLeaves > 0) {
    final count = threads.unresolvedReviewerLeaves;
    return '❌ Address $count unresolved reviewer comment(s)';
  }
  if (crVotes.any((v) => v.endsWith(':-1') || v.endsWith(':-2'))) {
    return '❌ Address negative Code-Review (${crVotes.join(', ')})';
  }
  if (cqStatus.startsWith('❌')) {
    return '❌ Fix failing CQ tryjobs';
  }
  if (threads.unresolvedAuthorLeaves > 0) {
    final target = reviewers.isEmpty ? 'Reviewer' : reviewers.join(', ');
    return '🔔 Ping $target (${threads.unresolvedAuthorLeaves} open thread(s))';
  }
  if (crVotes.any((v) => v.endsWith(':+1') || v.endsWith(':+2'))) {
    return '🚀 Approved (${crVotes.join(', ')})';
  }
  if (reviewers.isEmpty) {
    return '⚠️ Add Reviewer (0 assigned)';
  }
  return '⏳ Awaiting Review (${reviewers.join(', ')})';
}

List<String> _extractReviewers(Map<String, dynamic> item, int? ownerId) {
  final reviewersMap = item['reviewers'] as Map<String, dynamic>?;
  final list = reviewersMap?['REVIEWER'] as List<dynamic>? ?? const [];
  final names = <String>[];
  for (final r in list) {
    if (r is! Map<String, dynamic>) continue;
    if (ownerId != null && r['_account_id'] == ownerId) continue;
    final name = (r['name'] ?? r['email'] ?? '').toString().trim();
    if (name.isNotEmpty) names.add(name);
  }
  return names;
}

List<String> _extractCrVotes(Map<String, dynamic> item, int? ownerId) {
  final labels = item['labels'] as Map<String, dynamic>?;
  final cr = labels?['Code-Review'] as Map<String, dynamic>?;
  final all = cr?['all'] as List<dynamic>? ?? const [];
  final votes = <String>[];
  for (final v in all) {
    if (v is! Map<String, dynamic>) continue;
    if (ownerId != null && v['_account_id'] == ownerId) continue;
    final val = v['value'] as int? ?? 0;
    if (val == 0) continue;
    final name = (v['name'] ?? v['email'] ?? '?').toString().trim();
    final sign = val > 0 ? '+$val' : '$val';
    votes.add('$name:$sign');
  }
  return votes;
}

bool _hasActiveCqVote(Map<String, dynamic> item) {
  final labels = item['labels'] as Map<String, dynamic>?;
  final cq = labels?['Commit-Queue'] as Map<String, dynamic>?;
  final all = cq?['all'] as List<dynamic>? ?? const [];
  return all.any(
    (v) => v is Map<String, dynamic> && (v['value'] as int? ?? 0) > 0,
  );
}

String _nextCqStatus(
  String current,
  String msg,
  String date,
  bool activeCqVote,
) {
  if (msg.contains('This CL has passed the run')) return '✅ Passed ($date)';
  if (msg.contains('This CL has failed the run')) return '❌ Failed ($date)';
  if (msg.contains('-Commit-Queue') && current.startsWith('⏳')) return 'None';
  if (msg.contains('Dry run: CV is trying the patch') && activeCqVote) {
    return '⏳ Running ($date)';
  }
  return current;
}

(String, String) extractGerritMessagesTelemetry(
  Map<String, dynamic> item,
  int? ownerId,
  int currentRevisionNumber,
) {
  final created = (item['created'] as String? ?? '').split(' ').first;
  var lastAuthorTouch = created;
  var cqStatus = 'None';
  final activeCqVote = _hasActiveCqVote(item);

  final messages = item['messages'] as List<dynamic>? ?? const [];
  for (final m in messages) {
    if (m is! Map<String, dynamic>) continue;
    final date = (m['date'] as String? ?? '').split(' ').first;
    final effectiveAuthor =
        (m['real_author'] ?? m['author']) as Map<String, dynamic>?;
    if (ownerId != null &&
        effectiveAuthor?['_account_id'] == ownerId &&
        date.isNotEmpty) {
      lastAuthorTouch = date;
    }
    final rev = m['_revision_number'] as int? ?? currentRevisionNumber;
    if (rev != currentRevisionNumber) continue;
    final msg = m['message'] as String? ?? '';
    cqStatus = _nextCqStatus(cqStatus, msg, date, activeCqVote);
  }
  return (lastAuthorTouch, cqStatus);
}

ThreadSummary _fetchClCommentSummary(
  String actualRepoRoot,
  String gerritHost,
  int clNumber,
  int? ownerId,
) {
  final gobResult = Process.runSync('gob-curl', [
    'https://$gerritHost/changes/$clNumber/comments',
  ], workingDirectory: actualRepoRoot);
  if (gobResult.exitCode != 0) {
    return (
      totalThreads: 0,
      unresolvedReviewerLeaves: 0,
      unresolvedAuthorLeaves: 0,
    );
  }
  final cleaned = (gobResult.stdout as String)
      .trim()
      .replaceFirst(")]}'", '')
      .trim();
  try {
    final decoded = jsonDecode(cleaned);
    if (decoded is Map<String, dynamic>) {
      return parseGerritCommentsJson(decoded, ownerId);
    }
  } catch (_) {}
  return (
    totalThreads: 0,
    unresolvedReviewerLeaves: 0,
    unresolvedAuthorLeaves: 0,
  );
}

RemoteCL? _parseRemoteClItem(
  Map<String, dynamic> item,
  String actualRepoRoot,
  String gerritHost,
) {
  if (item case {
    '_number': final int number,
    'change_id': final String changeId,
    'subject': final String subject,
    'status': final String status,
    'current_revision': final String currentRevision,
    'revisions': final Map<String, dynamic> revisions,
  }) {
    final currentRevisionNumber =
        (revisions[currentRevision] as Map<String, dynamic>?)?['_number']
            as int? ??
        1;
    final ownerMap = item['owner'] as Map<String, dynamic>?;
    final ownerId = ownerMap?['_account_id'] as int?;
    final reviewers = _extractReviewers(item, ownerId);
    final crVotes = _extractCrVotes(item, ownerId);
    final (lastAuthorTouch, cqStatus) = extractGerritMessagesTelemetry(
      item,
      ownerId,
      currentRevisionNumber,
    );
    final threads = _fetchClCommentSummary(
      actualRepoRoot,
      gerritHost,
      number,
      ownerId,
    );
    final nextAction = computeGerritNextAction(
      reviewers: reviewers,
      crVotes: crVotes,
      cqStatus: cqStatus,
      threads: threads,
    );
    return (
      number: number,
      changeId: changeId,
      subject: subject,
      status: status,
      currentRevision: currentRevision,
      currentRevisionNumber: currentRevisionNumber,
      lastAuthorTouch: lastAuthorTouch,
      reviewers: reviewers,
      crVotes: crVotes,
      cqStatus: cqStatus,
      threads: threads,
      nextAction: nextAction,
    );
  }
  return null;
}

const _changesQuerySuffix =
    'changes/?q=owner:self+status:open'
    '&o=CURRENT_REVISION&o=DETAILED_LABELS&o=DETAILED_ACCOUNTS&o=MESSAGES';

Map<int, RemoteCL> _fetchRemoteCLs(String actualRepoRoot, String gerritHost) {
  print(styleDim.wrap('Querying active CLs from Gerrit...')!);
  final gobResult = Process.runSync('gob-curl', [
    'https://$gerritHost/$_changesQuerySuffix',
  ], workingDirectory: actualRepoRoot);
  if (gobResult.exitCode != 0) {
    throw GerritViewException(
      'Failed to execute gob-curl. Is it in your PATH and authenticated?\n'
      'Error: ${gobResult.stderr}',
      exitCode: ExitCode.software.code,
    );
  }

  final rawJson = (gobResult.stdout as String).trim();
  final cleanedJson = rawJson.replaceFirst(")]}'", '').trim();

  List<dynamic> clList;
  try {
    clList = jsonDecode(cleanedJson) as List<dynamic>;
  } catch (e) {
    throw GerritViewException(
      'Failed to parse Gerrit response: $e\nRaw output:\n$cleanedJson',
      exitCode: ExitCode.software.code,
    );
  }

  final remoteCLs = <int, RemoteCL>{};
  for (final item in clList) {
    if (item is! Map<String, dynamic>) continue;
    final parsed = _parseRemoteClItem(item, actualRepoRoot, gerritHost);
    if (parsed != null) {
      remoteCLs[parsed.number] = parsed;
    }
  }
  return remoteCLs;
}

List<String> _listAllLocalBranches(String actualRepoRoot) {
  final res = Process.runSync('git', [
    'for-each-ref',
    '--format=%(refname:short)',
    'refs/heads/',
  ], workingDirectory: actualRepoRoot);
  if (res.exitCode != 0) return const [];
  return (res.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

Map<String, int> _readConfiguredBranchIssues(String actualRepoRoot) {
  final localBranchIssues = <String, int>{};
  final configResult = Process.runSync('git', [
    'config',
    '--get-regexp',
    r'branch\..*\.gerritissue',
  ], workingDirectory: actualRepoRoot);
  if (configResult.exitCode != 0) return localBranchIssues;

  final lines = (configResult.stdout as String).trim().split('\n');
  for (final line in lines) {
    final entry = _parseBranchIssueLine(line);
    if (entry != null) {
      localBranchIssues[entry.$1] = entry.$2;
    }
  }
  return localBranchIssues;
}

(Map<String, int>, Map<String, CommitDetails>) _discoverLocalBranchIssues(
  String actualRepoRoot,
  Map<int, RemoteCL> remoteCLs,
  String defaultBranch,
) {
  final localBranchIssues = _readConfiguredBranchIssues(actualRepoRoot);
  final branchDetails = <String, CommitDetails>{};

  final byChangeId = <String, int>{
    for (final cl in remoteCLs.values)
      if (cl.changeId.isNotEmpty) cl.changeId: cl.number,
  };
  final bySha = <String, int>{
    for (final cl in remoteCLs.values) cl.currentRevision: cl.number,
  };

  final allBranches = <String>{
    ...localBranchIssues.keys,
    ..._listAllLocalBranches(actualRepoRoot),
  };

  for (final branch in allBranches) {
    if (branch == defaultBranch && !localBranchIssues.containsKey(branch)) {
      continue;
    }
    final details = _fetchCommitDetails(actualRepoRoot, branch);
    if (details == null) continue;
    branchDetails[branch] = details;

    if (branch != defaultBranch) {
      final matchedIssue = bySha[details.sha] ?? byChangeId[details.changeId];
      if (matchedIssue != null) {
        localBranchIssues.putIfAbsent(branch, () => matchedIssue);
      }
    }
  }

  return (localBranchIssues, branchDetails);
}

final _branchIssueRegex = RegExp(r'^branch\.(.*)\.gerritissue$');

(String, int)? _parseBranchIssueLine(String line) {
  if (line.isEmpty) return null;
  final lastSpace = line.lastIndexOf(' ');
  if (lastSpace == -1) return null;
  final key = line.substring(0, lastSpace);
  final issueVal = int.tryParse(line.substring(lastSpace + 1));
  if (issueVal == null) return null;
  final match = _branchIssueRegex.firstMatch(key);
  if (match == null) return null;
  return (match.group(1)!, issueVal);
}

Map<int, List<String>> _identifyConflatedBranches(
  Map<String, int> localBranchIssues,
  Map<int, RemoteCL> remoteCLs,
) {
  final issueToBranches = <int, List<String>>{};
  for (final entry in localBranchIssues.entries) {
    if (!remoteCLs.containsKey(entry.value)) continue;
    issueToBranches.putIfAbsent(entry.value, () => []).add(entry.key);
  }

  return <int, List<String>>{
    for (final entry in issueToBranches.entries)
      if (entry.value.length > 1) entry.key: entry.value,
  };
}

Map<int, RemoteCL> _findRemoteOnlyCLs(
  Map<int, RemoteCL> remoteCLs,
  Map<String, int> localBranchIssues,
) {
  final mappedIssues = localBranchIssues.values.toSet();
  return <int, RemoteCL>{
    for (final cl in remoteCLs.values)
      if (!mappedIssues.contains(cl.number)) cl.number: cl,
  };
}

_BranchAnalysis _buildBranchGroups(
  String actualRepoRoot,
  Map<int, RemoteCL> remoteCLs,
  Map<String, int> localBranchIssues,
  Map<String, CommitDetails> branchDetails,
  Map<int, ClStatus> closedStatuses,
) {
  final alignedBranches =
      <String, (RemoteCL, CommitDetails, AlignmentResult)>{};
  final closedClBranches = <String, (int, CommitDetails, ClStatus)>{};
  final mismatchedChangeIdBranches = <String, (RemoteCL, CommitDetails)>{};
  final conflatedBranches = _identifyConflatedBranches(
    localBranchIssues,
    remoteCLs,
  );

  for (final branch in localBranchIssues.keys) {
    final issue = localBranchIssues[branch]!;
    final details = branchDetails[branch];
    if (details == null) continue;

    final remote = remoteCLs[issue];
    if (remote == null) {
      closedClBranches[branch] = (
        issue,
        details,
        closedStatuses[issue] ?? ClStatus.unknown,
      );
      continue;
    }

    if (details.changeId.isNotEmpty && details.changeId != remote.changeId) {
      mismatchedChangeIdBranches[branch] = (remote, details);
      continue;
    }

    if (conflatedBranches.containsKey(issue)) continue;

    alignedBranches[branch] = (
      remote,
      details,
      calculateAlignment(actualRepoRoot, branch, details, remote),
    );
  }

  return (
    alignedBranches: alignedBranches,
    closedClBranches: closedClBranches,
    conflatedBranches: conflatedBranches,
    mismatchedChangeIdBranches: mismatchedChangeIdBranches,
    remoteOnlyCLs: _findRemoteOnlyCLs(remoteCLs, localBranchIssues),
  );
}

final _changeIdRegex = RegExp(
  r'^Change-Id:\s+(I[a-fA-F0-9]+)\s*$',
  multiLine: true,
  caseSensitive: false,
);

CommitDetails? _fetchCommitDetails(String repoPath, String branchName) {
  final result = Process.runSync('git', [
    'log',
    '-n',
    '1',
    '--format=COMMIT_METADATA_START%n%H%n%ar%n%B',
    branchName,
  ], workingDirectory: repoPath);
  if (result.exitCode != 0) return null;

  final output = result.stdout as String;
  if (!output.startsWith('COMMIT_METADATA_START\n')) return null;

  final lines = output.substring('COMMIT_METADATA_START\n'.length).split('\n');
  if (lines case [final String rawSha, final String rawRelativeDate, ...]) {
    final sha = rawSha.trim();
    final relativeDate = rawRelativeDate.trim();
    final rawBody = lines.sublist(2).join('\n');

    var changeId = '';
    final changeIdMatch = _changeIdRegex.firstMatch(rawBody);
    if (changeIdMatch != null) {
      changeId = changeIdMatch.group(1)!;
    }

    return (
      sha: sha,
      relativeDate: relativeDate,
      changeId: changeId,
      rawBody: rawBody,
    );
  }

  return null;
}

String? _buildClosedClQuery(List<int> clNumbers, Set<String> changeIds) {
  final issueTerms = clNumbers.map((n) => 'change:$n').join('+OR+');
  final cidTerms = changeIds.map((c) => 'change:$c').join('+OR+');
  if (issueTerms.isNotEmpty && cidTerms.isNotEmpty) {
    return '($issueTerms)+OR+(owner:self+($cidTerms))';
  }
  if (cidTerms.isNotEmpty) return 'owner:self+($cidTerms)';
  if (issueTerms.isNotEmpty) return issueTerms;
  return null;
}

Map<int, ClStatus> _resolveClosedAndUnmappedCLs(
  String repoPath,
  Map<String, int> localBranchIssues,
  Map<String, CommitDetails> branchDetails,
  Map<int, RemoteCL> remoteCLs,
  String defaultBranch,
  String gerritHost,
) {
  final closedIssues = localBranchIssues.values
      .where((i) => !remoteCLs.containsKey(i))
      .toSet()
      .toList();
  final unmappedChangeIds = <String>{
    for (final entry in branchDetails.entries)
      if (entry.key != defaultBranch &&
          !localBranchIssues.containsKey(entry.key) &&
          entry.value.changeId.isNotEmpty)
        entry.value.changeId,
  };

  final statuses = <int, ClStatus>{};
  final query = _buildClosedClQuery(closedIssues, unmappedChangeIds);
  if (query == null) return statuses;

  final result = Process.runSync('gob-curl', [
    'https://$gerritHost/changes/?q=$query',
  ], workingDirectory: repoPath);
  if (result.exitCode != 0) return statuses;

  final cleanedJson = (result.stdout as String)
      .trim()
      .replaceFirst(")]}'", '')
      .trim();
  final issueByChangeId = <String, int>{};
  try {
    final list = jsonDecode(cleanedJson) as List<dynamic>;
    for (final item in list) {
      if (item case {
        '_number': final int number,
        'status': final String status,
        'change_id': final String changeId,
      }) {
        statuses[number] = ClStatus.parse(status);
        issueByChangeId[changeId] = number;
      }
    }
  } catch (_) {}

  for (final entry in branchDetails.entries) {
    if (entry.key == defaultBranch) continue;
    final matchedIssue = issueByChangeId[entry.value.changeId];
    if (matchedIssue != null) {
      localBranchIssues.putIfAbsent(entry.key, () => matchedIssue);
    }
  }
  return statuses;
}

List<String> _buildShadowFetchRefs(
  Map<String, int> localBranchIssues,
  Map<String, CommitDetails> branchDetails,
  Map<int, RemoteCL> remoteCLs,
) {
  final fetchRefs = <String>[];
  for (final branch in localBranchIssues.keys) {
    final issue = localBranchIssues[branch]!;
    final details = branchDetails[branch];
    final remote = remoteCLs[issue];
    if (details != null &&
        remote != null &&
        details.sha != remote.currentRevision) {
      final lastTwo = (remote.number % 100).toString().padLeft(2, '0');
      fetchRefs.add(
        'refs/changes/$lastTwo/${remote.number}/${remote.currentRevisionNumber}',
      );
    }
  }
  return fetchRefs;
}

Future<void> runGerritView({String? gerritRepo}) async {
  final actualRepoRoot = _resolveRepoInfo(gerritRepo);
  final (gerritHost, gerritProject, _) = _resolveGerritDetails(actualRepoRoot);
  final defaultBranch = _getDefaultBranch(actualRepoRoot);
  final currentBranch = _getCurrentBranch(actualRepoRoot);

  final remoteCLs = _fetchRemoteCLs(actualRepoRoot, gerritHost);
  final (localBranchIssues, branchDetails) = _discoverLocalBranchIssues(
    actualRepoRoot,
    remoteCLs,
    defaultBranch,
  );

  final closedStatuses = _resolveClosedAndUnmappedCLs(
    actualRepoRoot,
    localBranchIssues,
    branchDetails,
    remoteCLs,
    defaultBranch,
    gerritHost,
  );

  final fetchRefs = _buildShadowFetchRefs(
    localBranchIssues,
    branchDetails,
    remoteCLs,
  );

  if (fetchRefs.isNotEmpty) {
    final gerritRemote = _resolveGerritRemoteName(actualRepoRoot);
    print(
      styleDim.wrap('Fetching remote changes from Gerrit ($gerritRemote)...')!,
    );
    final fetchResult = await Process.start(
      'git',
      ['fetch', gerritRemote, ...fetchRefs],
      workingDirectory: actualRepoRoot,
      mode: ProcessStartMode.inheritStdio,
    );
    if (await fetchResult.exitCode != 0) {
      print(
        yellow.wrap(
          'Warning: Batch fetch failed. Alignment checks will use local cache.',
        )!,
      );
    }
  }

  final analysis = _buildBranchGroups(
    actualRepoRoot,
    remoteCLs,
    localBranchIssues,
    branchDetails,
    closedStatuses,
  );

  groupAndPrintReport(
    actualRepoRoot: actualRepoRoot,
    defaultBranch: defaultBranch,
    currentBranch: currentBranch,
    gerritHost: gerritHost,
    gerritProject: gerritProject,
    alignedBranches: analysis.alignedBranches,
    closedClBranches: analysis.closedClBranches,
    conflatedBranches: analysis.conflatedBranches,
    mismatchedChangeIdBranches: analysis.mismatchedChangeIdBranches,
    remoteOnlyCLs: analysis.remoteOnlyCLs,
    remoteCLs: remoteCLs,
    branchDetails: branchDetails,
  );
}
