import 'dart:io';

import 'package:io/ansi.dart';
import 'package:io/io.dart';

import 'gerrit_view/gerrit_queries.dart';
import 'gerrit_view/report_printer.dart';
import 'git_extensions.dart';

export 'gerrit_view/gerrit_queries.dart'
    show
        AlignmentResult,
        AlignmentState,
        ClStatus,
        CleanupSafety,
        CommitDetails,
        GerritViewException,
        RemoteCL,
        ThreadSummary,
        computeGerritNextAction,
        extractGerritMessagesTelemetry,
        parseGerritCommentsJson;
export 'gerrit_view/report_printer.dart';

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
  final gerritRemote = resolveGerritRemoteName(repoPath);
  final result = Process.runSync('git', [
    'cherry',
    '$gerritRemote/$defaultBranch',
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

String resolveGerritRemoteName(String actualRepoRoot) {
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
  final remoteName = resolveGerritRemoteName(actualRepoRoot);
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
  final defaultBranch = sniffDefaultBranchSync(actualRepoRoot);
  final currentBranch = _getCurrentBranch(actualRepoRoot);

  final remoteCLs = fetchRemoteCLs(actualRepoRoot, gerritHost);
  final (localBranchIssues, branchDetails) = _discoverLocalBranchIssues(
    actualRepoRoot,
    remoteCLs,
    defaultBranch,
  );

  final closedStatuses = resolveClosedAndUnmappedCLs(
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
    final gerritRemote = resolveGerritRemoteName(actualRepoRoot);
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

  groupAndPrintReport(
    actualRepoRoot: actualRepoRoot,
    defaultBranch: defaultBranch,
    currentBranch: currentBranch,
    gerritHost: gerritHost,
    gerritProject: gerritProject,
    alignedBranches: alignedBranches,
    closedClBranches: closedClBranches,
    conflatedBranches: conflatedBranches,
    mismatchedChangeIdBranches: mismatchedChangeIdBranches,
    remoteOnlyCLs: _findRemoteOnlyCLs(remoteCLs, localBranchIssues),
    remoteCLs: remoteCLs,
    branchDetails: branchDetails,
  );
}
