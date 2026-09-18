import 'dart:io';

import 'package:io/ansi.dart';

import 'gerrit_view/gerrit_queries.dart';
import 'gerrit_view/models.dart';
import 'gerrit_view/report_printer.dart';

export 'gerrit_view/models.dart'
    show
        AlignmentResult,
        AlignmentState,
        ClStatus,
        CleanupSafety,
        CommitDetails,
        GerritViewException,
        RemoteCL;

Future<void> runGerritView({String? gerritRepo}) async {
  final actualRepoRoot = resolveRepoInfo(gerritRepo);
  final (gerritHost, gerritProject, _) = resolveGerritDetails(actualRepoRoot);

  final remoteCLs = fetchRemoteCLs(actualRepoRoot, gerritHost);
  final localBranchIssues = fetchLocalBranchIssues(actualRepoRoot);

  final branchDetails = <String, CommitDetails>{};
  for (final branch in localBranchIssues.keys) {
    final details = fetchCommitDetails(actualRepoRoot, branch);
    if (details != null) branchDetails[branch] = details;
  }

  final defaultBranch = getDefaultBranch(actualRepoRoot);
  final currentBranch = getCurrentBranch(actualRepoRoot);

  final closedIssues = localBranchIssues.values
      .where((i) => !remoteCLs.containsKey(i))
      .toSet()
      .toList();
  final closedStatuses = fetchRemoteCLStatuses(
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

  final analysis = buildBranchGroups(
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
