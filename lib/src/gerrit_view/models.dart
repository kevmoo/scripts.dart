import 'dart:io';

import 'package:io/ansi.dart';
import 'package:meta/meta.dart';

import '../git_extensions.dart';
import '../shared/gh_args.dart';

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

@internal
typedef BranchAnalysis = ({
  Map<String, (RemoteCL, CommitDetails, AlignmentResult)> alignedBranches,
  Map<String, (int, CommitDetails, ClStatus)> closedClBranches,
  Map<int, List<String>> conflatedBranches,
  Map<String, (RemoteCL, CommitDetails)> mismatchedChangeIdBranches,
  Map<int, RemoteCL> remoteOnlyCLs,
});

typedef CleanupSafety = ({bool isSafe, List<String> unmergedShas});

@internal
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

@internal
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

  final lines = output.split('\n');
  final unmerged = <String>[];
  for (final line in lines) {
    if (line.startsWith('+ ')) {
      unmerged.add(line.substring(2).trim());
    }
  }

  return (isSafe: unmerged.isEmpty, unmergedShas: unmerged);
}

@internal
String getDefaultBranch(String repoPath) => sniffDefaultBranchSync(repoPath);

@internal
String? getCurrentBranch(String repoPath) {
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

@internal
Map<String, String> getWorktreeBranches(String repoPath) {
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
