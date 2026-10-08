import 'dart:convert';

import 'pr_context.dart';

/// Sync status information comparing local repository state to remote PR state.
typedef PrSyncStatus = ({
  String localBranch,
  String remoteBranch,
  String localHeadSha,
  String remoteHeadSha,
  bool isSynced,
  String syncState,
  String? warning,
});

/// Evaluates local git repository branch and commit SHA against the remote PR
/// head branch and commit SHA.
Future<PrSyncStatus> fetchPrSyncStatus(
  PrContext context, {
  String? remoteBranch,
  String? remoteHeadSha,
  CommandRunner runCommand = runCommand,
}) async {
  final (rBranch, rHeadSha) = await _resolveRemoteBranchAndSha(
    context,
    remoteBranch: remoteBranch,
    remoteHeadSha: remoteHeadSha,
    runCommand: runCommand,
  );
  final localBranch = await _resolveLocalBranch(context.workingDir, runCommand);
  final localHeadSha = await _resolveLocalHeadSha(
    context.workingDir,
    runCommand,
  );

  PrSyncStatus buildStatus({
    required bool isSynced,
    required String syncState,
    required String? warning,
  }) => (
    localBranch: localBranch,
    remoteBranch: rBranch,
    localHeadSha: localHeadSha,
    remoteHeadSha: rHeadSha,
    isSynced: isSynced,
    syncState: syncState,
    warning: warning,
  );

  if (localBranch.isNotEmpty && rBranch.isNotEmpty && localBranch != rBranch) {
    return buildStatus(
      isSynced: false,
      syncState: 'branch_mismatch',
      warning:
          'Active local branch is "$localBranch", but the PR branch is '
          '"$rBranch". Please checkout the correct branch using: '
          'gh pr checkout ${context.prNumber}',
    );
  }

  if (localHeadSha.isEmpty || rHeadSha.isEmpty) {
    return buildStatus(
      isSynced: false,
      syncState: 'unknown',
      warning: localHeadSha.isEmpty
          ? 'Could not determine local HEAD commit SHA. Please ensure you are '
                'in a valid git repository.'
          : 'Could not determine remote PR head commit SHA. Please check '
                'network connection or GitHub CLI status.',
    );
  }

  if (localHeadSha == rHeadSha) {
    return buildStatus(isSynced: true, syncState: 'in_sync', warning: null);
  }

  final (syncState, warning) = await _compareDiffCommits(
    context.workingDir,
    localHeadSha: localHeadSha,
    remoteHeadSha: rHeadSha,
    runCommand: runCommand,
  );
  return buildStatus(isSynced: false, syncState: syncState, warning: warning);
}

Future<(String, String)> _resolveRemoteBranchAndSha(
  PrContext context, {
  required String? remoteBranch,
  required String? remoteHeadSha,
  required CommandRunner runCommand,
}) async {
  if (remoteBranch != null && remoteHeadSha != null) {
    return (remoteBranch, remoteHeadSha);
  }
  try {
    final viewOutput = await runCommand('gh', [
      '-R',
      '${context.owner}/${context.repo}',
      'pr',
      'view',
      context.prNumber,
      '--json',
      'headRefName,headRefOid',
    ], workingDirectory: context.workingDir);
    final prData = jsonDecode(viewOutput) as Map<String, dynamic>;
    return (
      remoteBranch ?? prData['headRefName']?.toString() ?? '',
      remoteHeadSha ?? prData['headRefOid']?.toString() ?? '',
    );
  } catch (_) {
    return (remoteBranch ?? '', remoteHeadSha ?? '');
  }
}

Future<String> _resolveLocalBranch(
  String workingDir,
  CommandRunner runCommand,
) async {
  try {
    return (await runCommand('git', [
      'symbolic-ref',
      '--short',
      'HEAD',
    ], workingDirectory: workingDir)).trim();
  } catch (_) {
    try {
      return (await runCommand('git', [
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ], workingDirectory: workingDir)).trim();
    } catch (_) {
      return '';
    }
  }
}

Future<String> _resolveLocalHeadSha(
  String workingDir,
  CommandRunner runCommand,
) async {
  try {
    return (await runCommand('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: workingDir)).trim();
  } catch (_) {
    return '';
  }
}

Future<bool> _gitCheck(
  String workingDir,
  List<String> args,
  CommandRunner runCommand,
) async {
  try {
    await runCommand('git', args, workingDirectory: workingDir);
    return true;
  } catch (_) {
    return false;
  }
}

Future<(String syncState, String warning)> _compareDiffCommits(
  String workingDir, {
  required String localHeadSha,
  required String remoteHeadSha,
  required CommandRunner runCommand,
}) async {
  final remoteCommitExists = await _gitCheck(workingDir, [
    'cat-file',
    '-e',
    '$remoteHeadSha^{commit}',
  ], runCommand);
  if (!remoteCommitExists) {
    return (
      'not_fetched',
      'Remote PR commit ($remoteHeadSha) is not present in your local '
          'repository. Please run "git fetch" to update your local repository.',
    );
  }

  final isLocalAncestor = await _gitCheck(workingDir, [
    'merge-base',
    '--is-ancestor',
    localHeadSha,
    remoteHeadSha,
  ], runCommand);
  if (isLocalAncestor) {
    return (
      'behind_remote',
      'Local commit ($localHeadSha) is behind remote PR commit '
          '($remoteHeadSha). Please pull remote changes before making edits.',
    );
  }

  final isRemoteAncestor = await _gitCheck(workingDir, [
    'merge-base',
    '--is-ancestor',
    remoteHeadSha,
    localHeadSha,
  ], runCommand);
  if (isRemoteAncestor) {
    return (
      'ahead_of_remote',
      'Local commit ($localHeadSha) is ahead of remote PR commit '
          '($remoteHeadSha). Please push local commits to sync remote PR.',
    );
  }

  return (
    'diverged',
    'Local commit ($localHeadSha) and remote PR commit ($remoteHeadSha) have '
        'diverged. Please sync local and remote branches.',
  );
}
