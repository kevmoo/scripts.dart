import 'dart:convert';
import 'dart:io';

import 'package:io/ansi.dart';
import 'package:io/io.dart';

import 'git_extensions.dart';
import 'shared/gh_args.dart';

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

typedef RemoteCL = ({
  int number,
  String changeId,
  String subject,
  String status,
  String currentRevision,
  int currentRevisionNumber,
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

String _resolveRepoInfo(String? gerritRepo) {
  final repoPath = gerritRepo == null
      ? Directory.current.absolute.path
      : Directory(gerritRepo).absolute.path;
  final checkResult = Process.runSync('git', [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: repoPath);
  if (checkResult.exitCode != 0) {
    throw GerritViewException(
      'Directory "$repoPath" is not a Git repository (or git is missing).',
      exitCode: ExitCode.config.code,
    );
  }
  return (checkResult.stdout as String).trim();
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

String? _parseGerritHostFromConfig(String actualRepoRoot) {
  final serverResult = Process.runSync('git', [
    'config',
    '--get-regexp',
    r'branch\..*\.gerritserver',
  ], workingDirectory: actualRepoRoot);
  if (serverResult.exitCode == 0) {
    final lines = (serverResult.stdout as String).trim().split('\n');
    for (final line in lines) {
      if (line.isEmpty) continue;
      final lastSpace = line.lastIndexOf(' ');
      if (lastSpace != -1) {
        final url = line.substring(lastSpace + 1).trim();
        final uri = Uri.tryParse(url);
        if (uri != null && uri.host.isNotEmpty) return uri.host;
      }
    }
  }
  return null;
}

(String, String?)? _parseRemoteOrigin(String actualRepoRoot) {
  final remoteUrl = _getGitConfig('remote.origin.url', actualRepoRoot);
  if (remoteUrl != null &&
      (remoteUrl.contains('googlesource.com') ||
          remoteUrl.contains('review.chrome'))) {
    final uri = Uri.tryParse(remoteUrl);
    if (uri != null && uri.host.isNotEmpty) {
      final gHost = uri.host;
      String? gProject;
      if (uri.pathSegments.isNotEmpty) {
        final lastSeg = uri.pathSegments.last;
        gProject = lastSeg.endsWith('.git')
            ? lastSeg.substring(0, lastSeg.length - 4)
            : lastSeg;
      }
      return (gHost, gProject);
    }
  }
  return null;
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

Map<int, RemoteCL> _fetchRemoteCLs(String actualRepoRoot, String gerritHost) {
  print(styleDim.wrap('Querying active CLs from Gerrit...')!);
  final gobResult = Process.runSync('gob-curl', [
    'https://$gerritHost/changes/?q=owner:self+status:open&o=CURRENT_REVISION',
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
      remoteCLs[number] = (
        number: number,
        changeId: changeId,
        subject: subject,
        status: status,
        currentRevision: currentRevision,
        currentRevisionNumber: currentRevisionNumber,
      );
    }
  }
  return remoteCLs;
}

Map<String, int> _fetchLocalBranchIssues(String actualRepoRoot) {
  final configResult = Process.runSync('git', [
    'config',
    '--get-regexp',
    r'branch\..*\.gerritissue',
  ], workingDirectory: actualRepoRoot);
  if (configResult.exitCode != 0) return {};

  final localBranchIssues = <String, int>{};
  final lines = (configResult.stdout as String).trim().split('\n');
  for (final line in lines) {
    final entry = _parseBranchIssueLine(line);
    if (entry != null) {
      localBranchIssues[entry.$1] = entry.$2;
    }
  }
  return localBranchIssues;
}

(String, int)? _parseBranchIssueLine(String line) {
  if (line.isEmpty) return null;
  final lastSpace = line.lastIndexOf(' ');
  if (lastSpace == -1) return null;
  final key = line.substring(0, lastSpace);
  final issueVal = int.tryParse(line.substring(lastSpace + 1));
  if (issueVal == null) return null;
  final match = RegExp(r'^branch\.(.*)\.gerritissue$').firstMatch(key);
  if (match == null) return null;
  return (match.group(1)!, issueVal);
}

Map<int, List<String>> _identifyConflatedBranches(
  Map<String, int> localBranchIssues,
) {
  final issueToBranches = <int, List<String>>{};
  for (final entry in localBranchIssues.entries) {
    issueToBranches.putIfAbsent(entry.value, () => []).add(entry.key);
  }

  final conflatedBranches = <int, List<String>>{};
  for (final entry in issueToBranches.entries) {
    if (entry.value.length > 1) conflatedBranches[entry.key] = entry.value;
  }
  return conflatedBranches;
}

Map<int, RemoteCL> _findRemoteOnlyCLs(
  Map<int, RemoteCL> remoteCLs,
  Map<String, int> localBranchIssues,
) {
  final remoteOnlyCLs = <int, RemoteCL>{};
  final mappedIssues = localBranchIssues.values.toSet();
  for (final cl in remoteCLs.values) {
    if (!mappedIssues.contains(cl.number)) remoteOnlyCLs[cl.number] = cl;
  }
  return remoteOnlyCLs;
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
  final conflatedBranches = _identifyConflatedBranches(localBranchIssues);

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

    if (details.changeId != remote.changeId) {
      mismatchedChangeIdBranches[branch] = (remote, details);
      continue;
    }

    if (conflatedBranches.containsKey(issue)) continue;

    alignedBranches[branch] = (
      remote,
      details,
      _calculateAlignment(actualRepoRoot, branch, details, remote),
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

void _printSection1Aligned(
  Map<String, (RemoteCL, CommitDetails, AlignmentResult)> alignedBranches,
  String gerritHost,
  String gerritProject,
  String? currentBranch,
) {
  if (alignedBranches.isEmpty) return;
  print(styleBold.wrap('✅ ACTIVE & ALIGNED LOCAL BRANCHES')!);
  for (final entry in alignedBranches.entries) {
    final branch = entry.key;
    final (remote, details, alignment) = entry.value;
    final String shaLine;
    if (alignment.state == AlignmentState.inSync) {
      shaLine = '    SHA:        ${remote.currentRevision}';
    } else {
      shaLine =
          '    Local SHA:  ${details.sha}\n'
          '    Remote SHA: ${remote.currentRevision}';
    }
    print('''
  ${branch == currentBranch ? '⭐' : '•'} ${styleBold.wrap(branch)} ➔ CL ${remote.number} (${styleDim.wrap(remote.subject)})
    URL:        https://$gerritHost/c/$gerritProject/+/${remote.number}
$shaLine
    Alignment:  ${alignment.display}
    Last Touch: ${details.relativeDate}
''');
  }
}

void _printSection2RemoteOnly(
  Map<int, RemoteCL> remoteOnlyCLs,
  String gerritHost,
  String gerritProject,
) {
  if (remoteOnlyCLs.isEmpty) return;
  print(styleBold.wrap('🌐 REMOTE-ONLY CLS (No local branch tracking)')!);
  print(
    styleDim.wrap(
      '   These open CLs are on Gerrit but have no corresponding local branch:',
    )!,
  );
  for (final cl in remoteOnlyCLs.values) {
    print('''
  • CL ${cl.number}: ${cl.subject}
    URL:        https://$gerritHost/c/$gerritProject/+/${cl.number}
    Remote SHA: ${cl.currentRevision}
''');
  }
}

void _printConflatedBranchRow(
  String branch,
  CommitDetails? details,
  RemoteCL? remote,
  String actualRepoRoot,
  String? currentBranch,
) {
  if (details == null) return;
  var changeIdStatus = '❌ MISMATCH';
  var shaStatus = '❌ OUT OF SYNC';
  var treeStatus = '❌ DIFFERENT';

  if (remote != null) {
    if (details.changeId == remote.changeId) {
      changeIdStatus = '✅ MATCH';
    } else if (details.changeId.isNotEmpty) {
      changeIdStatus = '⚠️ OTHER CL';
    }

    final alignment = _calculateAlignment(
      actualRepoRoot,
      branch,
      details,
      remote,
    );
    if (alignment.state == AlignmentState.inSync) {
      shaStatus = '✅ SYNCED';
      treeStatus = '✅ IDENTICAL';
    } else if (alignment.state == AlignmentState.contentIdentical) {
      shaStatus = '❌ OUT OF SYNC';
      treeStatus = '✅ IDENTICAL';
    }
  }

  final branchCol = (branch == currentBranch ? '⭐ $branch' : branch).padRight(
    branch == currentBranch ? 24 : 25,
  );
  final changeIdCol = changeIdStatus.padRight(12);
  final shaCol = shaStatus.padRight(12);
  final treeCol = treeStatus.padRight(15);
  final dateCol = details.relativeDate.padRight(15);
  print('    $branchCol $changeIdCol $shaCol $treeCol $dateCol');
}

void _printConflatedIssues(
  Map<int, List<String>> conflatedBranches,
  Map<int, RemoteCL> remoteCLs,
  Map<String, CommitDetails> branchDetails,
  String gerritHost,
  String gerritProject,
  String? currentBranch,
  String actualRepoRoot,
) {
  for (final entry in conflatedBranches.entries) {
    final issue = entry.key;
    final branchesList = entry.value;
    final remote = remoteCLs[issue];
    final subject = remote?.subject ?? 'Unknown CL';

    final urlLine = remote != null
        ? '    URL:        https://$gerritHost/c/$gerritProject/+/$issue\n'
        : '';
    final shaLine = remote != null
        ? '    Remote SHA: ${remote.currentRevision}\n'
        : '';
    final conflatedLabel = styleDim.wrap(
      'The following ${branchesList.length} branches target this CL:',
    );
    print('''
  ${red.wrap('• CONFLATED CL:')} $issue ($subject)
$urlLine$shaLine    $conflatedLabel
    ${'Branch'.padRight(25)} ${'Change-Id'.padRight(12)} ${'Commit SHA'.padRight(12)} ${'Tree (Content)'.padRight(15)} ${'Last Commit'.padRight(15)}
    --------------------------------------------------------------------''');

    for (final branch in branchesList) {
      _printConflatedBranchRow(
        branch,
        branchDetails[branch],
        remote,
        actualRepoRoot,
        currentBranch,
      );
    }
    print('');
  }
}

void _printMismatchedChangeIds(
  Map<String, (RemoteCL, CommitDetails)> mismatchedChangeIdBranches,
  String gerritHost,
  String gerritProject,
  String? currentBranch,
) {
  for (final entry in mismatchedChangeIdBranches.entries) {
    final branch = entry.key;
    final (remote, details) = entry.value;
    print('''
  ${branch == currentBranch ? '⭐' : red.wrap('•')} ${red.wrap('MISMATCHED CHANGE-ID:')} ${styleBold.wrap(branch)}
    Target CL:  ${remote.number} (${remote.subject})
    URL:        https://$gerritHost/c/$gerritProject/+/${remote.number}
    Local SHA:  ${details.sha}
    Remote SHA: ${remote.currentRevision}
    Local ID:   ${details.changeId}
    Remote ID:  ${remote.changeId}
    To Push:    git commit --amend (set Change-Id to: ${remote.changeId}) && git cl upload
''');
  }
}

void _printSection3ConflatedAndMismatched(
  Map<int, List<String>> conflatedBranches,
  Map<String, (RemoteCL, CommitDetails)> mismatchedChangeIdBranches,
  Map<int, RemoteCL> remoteCLs,
  Map<String, CommitDetails> branchDetails,
  String gerritHost,
  String gerritProject,
  String? currentBranch,
  String actualRepoRoot,
) {
  if (conflatedBranches.isEmpty && mismatchedChangeIdBranches.isEmpty) return;

  print(red.wrap(styleBold.wrap('⚠️  CONFLATED OR MISMATCHED BRANCHES')!)!);
  print(
    styleDim.wrap(
      '   These branches have conflicting configuration '
      'or divergent Change-Ids:',
    )!,
  );
  print('');

  _printConflatedIssues(
    conflatedBranches,
    remoteCLs,
    branchDetails,
    gerritHost,
    gerritProject,
    currentBranch,
    actualRepoRoot,
  );
  _printMismatchedChangeIds(
    mismatchedChangeIdBranches,
    gerritHost,
    gerritProject,
    currentBranch,
  );
}

void _printClosedClBranch(
  String branch,
  int issue,
  CommitDetails details,
  ClStatus status,
  String gerritHost,
  String gerritProject,
  String actualRepoRoot,
  String defaultBranch,
  String? currentBranch,
  Map<String, String> worktreeBranches,
) {
  final safety = _checkCleanupSafety(actualRepoRoot, branch, defaultBranch);
  final String safetyStatus;
  final String actionText;
  final worktreePath = worktreeBranches[branch];

  if (branch == defaultBranch) {
    safetyStatus = yellow.wrap(
      '⚠️  Protected Default Branch (Do NOT delete this branch!)',
    )!;
    actionText =
        '    Archive:    git config --unset branch.$branch.gerritissue';
  } else if (safety.isSafe) {
    safetyStatus = green.wrap(
      '✅ Safe to delete (All changes exist in origin/$defaultBranch)',
    )!;
    if (worktreePath != null) {
      actionText =
          '    Run:        git worktree remove $worktreePath --force '
          '&& git branch -D $branch';
    } else {
      actionText = '    Run:        git branch -D $branch';
    }
  } else {
    final count = safety.unmergedShas.length;
    safetyStatus = red.wrap(
      '⚠️  Warning: Has $count unmerged commit(s) not in origin/$defaultBranch!',
    )!;
    if (worktreePath != null) {
      actionText =
          '    Inspect:    git diff origin/$defaultBranch..$branch\n'
          '    Run:        git worktree remove $worktreePath --force '
          '&& git branch -D $branch\n'
          '    Archive:    git config --unset branch.$branch.gerritissue';
    } else {
      actionText =
          '    Inspect:    git diff origin/$defaultBranch..$branch\n'
          '    Run:        git branch -D $branch (Force discard)\n'
          '    Archive:    git config --unset branch.$branch.gerritissue';
    }
  }

  final styledStatus = switch (status) {
    ClStatus.merged => green.wrap(status.value)!,
    ClStatus.abandoned => yellow.wrap(status.value)!,
    ClStatus.newCl => styleBold.wrap(status.value)!,
    ClStatus.unknown => styleDim.wrap(status.value)!,
  };

  print('''
  ${branch == currentBranch ? '⭐' : '•'} ${styleBold.wrap(branch)} ➔ CL $issue [$styledStatus]
    URL:        https://$gerritHost/c/$gerritProject/+/$issue
    Last Touch: ${details.relativeDate}
    Safety:     $safetyStatus
$actionText
''');
}

void _printSection4ClosedAndAbandoned(
  Map<String, (int, CommitDetails, ClStatus)> closedClBranches,
  String gerritHost,
  String gerritProject,
  String actualRepoRoot,
  String defaultBranch,
  String? currentBranch,
) {
  if (closedClBranches.isEmpty) return;

  print(
    yellow.wrap(
      styleBold.wrap('🧹 CLEANUP CANDIDATES (Closed/Abandoned CL Branches)')!,
    )!,
  );
  print(
    styleDim.wrap(
      '   These local branches point to CLs that are '
      'merged, abandoned, or closed:',
    )!,
  );

  final worktreeBranches = _getWorktreeBranches(actualRepoRoot);
  for (final entry in closedClBranches.entries) {
    _printClosedClBranch(
      entry.key,
      entry.value.$1,
      entry.value.$2,
      entry.value.$3,
      gerritHost,
      gerritProject,
      actualRepoRoot,
      defaultBranch,
      currentBranch,
      worktreeBranches,
    );
  }
}

void _groupAndPrintReport({
  required String actualRepoRoot,
  required String defaultBranch,
  required String? currentBranch,
  required String gerritHost,
  required String gerritProject,
  required Map<String, (RemoteCL, CommitDetails, AlignmentResult)>
  alignedBranches,
  required Map<String, (int, CommitDetails, ClStatus)> closedClBranches,
  required Map<int, List<String>> conflatedBranches,
  required Map<String, (RemoteCL, CommitDetails)> mismatchedChangeIdBranches,
  required Map<int, RemoteCL> remoteOnlyCLs,
  required Map<int, RemoteCL> remoteCLs,
  required Map<String, CommitDetails> branchDetails,
}) {
  print(
    '''\n======================================================================
${styleBold.wrap('🔍 GERRIT WORKSPACE OVERVIEW')}
${styleDim.wrap('Repository: $actualRepoRoot')}
======================================================================\n''',
  );

  _printSection1Aligned(
    alignedBranches,
    gerritHost,
    gerritProject,
    currentBranch,
  );
  _printSection2RemoteOnly(remoteOnlyCLs, gerritHost, gerritProject);
  _printSection3ConflatedAndMismatched(
    conflatedBranches,
    mismatchedChangeIdBranches,
    remoteCLs,
    branchDetails,
    gerritHost,
    gerritProject,
    currentBranch,
    actualRepoRoot,
  );
  _printSection4ClosedAndAbandoned(
    closedClBranches,
    gerritHost,
    gerritProject,
    actualRepoRoot,
    defaultBranch,
    currentBranch,
  );
}

Future<void> runGerritView({String? gerritRepo}) async {
  final actualRepoRoot = _resolveRepoInfo(gerritRepo);
  final (gerritHost, gerritProject, _) = _resolveGerritDetails(actualRepoRoot);

  final remoteCLs = _fetchRemoteCLs(actualRepoRoot, gerritHost);
  final localBranchIssues = _fetchLocalBranchIssues(actualRepoRoot);

  final branchDetails = <String, CommitDetails>{};
  for (final branch in localBranchIssues.keys) {
    final details = _fetchCommitDetails(actualRepoRoot, branch);
    if (details != null) branchDetails[branch] = details;
  }

  final defaultBranch = _getDefaultBranch(actualRepoRoot);
  final currentBranch = _getCurrentBranch(actualRepoRoot);

  final closedIssues = localBranchIssues.values
      .where((i) => !remoteCLs.containsKey(i))
      .toSet()
      .toList();
  final closedStatuses = _fetchRemoteCLStatuses(
    actualRepoRoot,
    closedIssues,
    gerritHost,
  );

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

  if (fetchRefs.isNotEmpty) {
    print(styleDim.wrap('Fetching remote changes from Gerrit...')!);
    final fetchResult = await Process.start(
      'git',
      ['fetch', 'origin', ...fetchRefs],
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

  _groupAndPrintReport(
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
    final changeIdMatch = RegExp(
      r'^Change-Id:\s+(I[a-fA-F0-9]+)\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(rawBody);
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

Map<int, ClStatus> _fetchRemoteCLStatuses(
  String repoPath,
  List<int> clNumbers,
  String gerritHost,
) {
  final statuses = <int, ClStatus>{};
  if (clNumbers.isEmpty) return statuses;

  final query = clNumbers.map((n) => 'change:$n').join('+OR+');
  final result = Process.runSync('gob-curl', [
    'https://$gerritHost/changes/?q=$query',
  ], workingDirectory: repoPath);

  if (result.exitCode != 0) return statuses;

  final rawJson = (result.stdout as String).trim();
  final cleanedJson = rawJson.replaceFirst(")]}'", '').trim();

  try {
    final list = jsonDecode(cleanedJson) as List<dynamic>;
    for (final item in list) {
      if (item case {
        '_number': final int number,
        'status': final String status,
      }) {
        statuses[number] = ClStatus.parse(status);
      }
    }
  } catch (_) {
    // Fallback
  }

  return statuses;
}

AlignmentResult _calculateAlignment(
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

  // Check if remote commit exists locally after batch fetch
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

  // Read local tree hash
  final localTreeResult = Process.runSync('git', [
    'rev-parse',
    '$branchName^{tree}',
  ], workingDirectory: repoPath);

  if (remoteTreeResult.exitCode == 0 && localTreeResult.exitCode == 0) {
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

typedef CleanupSafety = ({bool isSafe, List<String> unmergedShas});

CleanupSafety _checkCleanupSafety(
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

  final lines = output.split('\n');
  final unmerged = <String>[];
  for (final line in lines) {
    if (line.startsWith('+ ')) {
      unmerged.add(line.substring(2).trim());
    }
  }

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

Map<String, String> _getWorktreeBranches(String repoPath) {
  final result = Process.runSync('git', [
    'worktree',
    'list',
    '--porcelain',
  ], workingDirectory: repoPath);

  if (result.exitCode != 0) return {};

  final worktrees = <String, String>{};
  final lines = (result.stdout as String).split('\n');
  String? currentWorktree;

  for (final line in lines) {
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
