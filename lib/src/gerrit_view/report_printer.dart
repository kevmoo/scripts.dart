import 'package:io/ansi.dart';

import '../gerrit_view.dart';

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

    final alignment = calculateAlignment(
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
  final safety = checkCleanupSafety(actualRepoRoot, branch, defaultBranch);
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

  final worktreeBranches = getWorktreeBranches(actualRepoRoot);
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

void groupAndPrintReport({
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
