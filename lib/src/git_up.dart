import 'dart:convert';
import 'dart:io';

import 'package:git/git.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart';

import 'repos_config.dart';
import 'shared/git_cli.dart';
import 'testable_print.dart';

/// PR metadata retrieved from GitHub API.
typedef PrInfo = ({
  String state,
  String baseBranch,
  String? headRefOid,
  String? url,
  int? number,
  String? mergeable,
});

bool mockGhAvailableForTesting = false;
bool mockGhUnavailableForTesting = false;
Map<String, PrInfo>? mockRecentPrsForTesting;

/// Safely switches to and updates the default branch of a Git repository.
///
/// This function orchestrates the following steps:
/// 1. Finds the Git root directory and loads any matching entry from
///    `~/.config/kscripts/repos.yaml`.
/// 2. Rejects secondary worktrees (unless `allowWorktree` is configured) and
///    dirty working trees.
/// 3. Runs the `before` hook (`repos.yaml` `before` or `git-up.before`).
/// 4. Runs the `repos.yaml` `override` command, or: determines the target
///    branch (`repos.yaml` `branch`, `origin/HEAD`, or fallback to
///    `main`/`master`), verifies that the local branch exists and tracks the
///    expected upstream, checks it out, pulls with `--ff-only`, and cleans up
///    gone branches (unless `cleanBranches: false`).
/// 5. Runs the `post` hook (`repos.yaml` `post` or `git-up.post`).
///
/// Throws a [GitUpException] if any step fails with a clear message and
/// exit code.
///
/// [workingDirectory] specifies the directory to start searching for the
/// Git root. Defaults to [Directory.current]`.path`.
Future<void> gitUp({
  String? workingDirectory,
  bool check = false,
  String? homeDirectory,
}) async {
  workingDirectory ??= Directory.current.path;

  final gitDir = await _getGitDir(workingDirectory);
  final repoConfig = loadGitUpRepoConfig(
    gitDir.path,
    homeDirectory: homeDirectory,
  );

  if (!(repoConfig?.allowWorktree ?? false) &&
      await gitDir.isSecondaryWorktree()) {
    final mainPath =
        await gitDir.getMainWorktreePath() ?? 'the main repository root';
    printError('Please move to "$mainPath" and run git-up again.');
    throw GitUpException('Cannot run git-up from inside a secondary worktree.');
  }

  if (!await gitDir.isWorkingTreeClean(includeUntracked: false)) {
    printError('Please commit or stash your changes and try again.');
    throw GitUpException('Working tree is dirty.');
  }

  await _runHookCommand(
    gitDir,
    configKey: 'git-up.before',
    hookName: 'Before',
    commandOverride: repoConfig?.before,
  );

  if (repoConfig?.override case final overrideCommand?) {
    if (check) _printCheckSkipped('override');
    await _runShellCommand(gitDir.path, overrideCommand, hookName: 'Override');
  } else {
    await _syncDefaultBranch(gitDir, repoConfig: repoConfig, check: check);
  }

  await _runHookCommand(
    gitDir,
    configKey: 'git-up.post',
    hookName: 'Post',
    commandOverride: repoConfig?.post,
  );
}

Future<void> _syncDefaultBranch(
  GitDir gitDir, {
  required GitUpRepoConfig? repoConfig,
  required bool check,
}) async {
  // 1. Determine Default Branch
  final defaultBranch = repoConfig?.branch ?? await getDefaultBranch(gitDir);

  final boldBranch = styleBold.wrap(defaultBranch) ?? defaultBranch;
  print(
    styleDim.wrap('Default branch: $boldBranch') ??
        'Default branch: $boldBranch',
  );

  // 2. Verify Alignment
  await verifyAlignment(
    gitDir,
    defaultBranch,
    expectedUpstream: repoConfig?.upstream,
  );

  // 3. Checkout default branch
  await _runGit(
    gitDir,
    ['checkout', defaultBranch],
    statusMessage: 'Checking out $defaultBranch...',
    errorMessage: 'Failed to checkout branch $defaultBranch',
  );

  // 4. Update with pull --ff-only
  await _runGit(
    gitDir,
    ['pull', '--ff-only'],
    statusMessage: 'Pulling updates...',
    errorMessage: 'Failed to pull updates',
  );

  print(
    green.wrap('Successfully updated $defaultBranch.') ??
        'Successfully updated $defaultBranch.',
  );

  if (repoConfig?.cleanBranches ?? true) {
    await _cleanBranches(gitDir, defaultBranch, check: check);
  } else if (check) {
    _printCheckSkipped('cleanBranches: false');
  }
}

void _printCheckSkipped(String reason) {
  final message = '--check skipped: repos.yaml sets $reason for this checkout.';
  print(styleDim.wrap(message) ?? message);
}

Future<void> _runGit(
  GitDir gitDir,
  List<String> args, {
  required String statusMessage,
  required String errorMessage,
}) async {
  print(styleDim.wrap(statusMessage) ?? statusMessage);
  final process = await Process.start(
    'git',
    args,
    workingDirectory: gitDir.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw GitUpException(errorMessage, exitCode: exitCode);
  }
}

/// Resolves the Git repository root directory.
///
/// Runs `git rev-parse --show-toplevel` from [workingDirectory].
///
/// Returns a [GitDir] instance for the repository.
///
/// Throws a [GitUpException] if the command fails or if it's not a Git
/// repository.
Future<GitDir> _getGitDir(String workingDirectory) async {
  try {
    final result = await defaultGitCli.run(
      const ['rev-parse', '--show-toplevel'],
      workingDirectory: workingDirectory,
      readOnly: true,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        const ['rev-parse', '--show-toplevel'],
        result.stderr as String,
        result.exitCode,
      );
    }
    final gitRoot = (result.stdout as String).trim();
    return await GitDir.fromExisting(gitRoot);
  } on ProcessException catch (e) {
    throw GitUpException(
      e.message.trim().isNotEmpty ? e.message.trim() : 'Failed to run git.',
      exitCode: e.errorCode,
    );
  }
}

/// Determines the default branch of the repository.
///
/// First tries to read `origin/HEAD`. If that fails, it sniffs for
/// `refs/remotes/origin/main` and `refs/remotes/origin/master`.
///
/// Returns the name of the default branch (e.g., 'main').
///
/// Throws a [GitUpException] if the default branch cannot be determined.
///
/// [gitDir] is the Git repository to query.
Future<String> getDefaultBranch(GitDir gitDir) async {
  // First check origin/HEAD directly to match original behavior and pass tests
  final revParseResult = await gitDir.runCommand([
    'rev-parse',
    '--abbrev-ref',
    'origin/HEAD',
  ], throwOnError: false);

  if (revParseResult.exitCode == 0) {
    if (parseOriginHeadBranchOutput(revParseResult.stdout as String)
        case final parsed?) {
      return parsed;
    }
  }

  // If origin/HEAD is missing, we can use the extension to see if it CAN sniff a branch,
  // so we can give a better error message (matching original behavior).
  final sniffedBranch = await gitDir.remoteDefaultBranch();

  printError('Error: origin/HEAD is not set for this repository.');
  if (sniffedBranch != null) {
    printError('It looks like the default branch might be "$sniffedBranch".');
    printError('You can configure it by running:');
    printError('  git remote set-head origin $sniffedBranch');
  } else {
    printError('Could not automatically determine the default branch.');
    printError('You can configure it by running:');
    printError('  git remote set-head origin <branch-name>');
  }

  throw GitUpException(
    'Cannot determine default branch.',
    exitCode: ExitCode.config.code,
  );
}

/// Verifies that the local branch is aligned with the remote default branch.
///
/// Checks:
/// 1. The local branch with name [defaultBranch] exists.
/// 2. The local branch has an upstream configured.
/// 3. The upstream matches [expectedUpstream] (defaults to
///    `origin/[defaultBranch]`).
///
/// Throws a [GitUpException] with specific advice if any check fails.
///
/// [gitDir] is the Git repository.
/// [defaultBranch] is the name of the default branch to verify.
Future<void> verifyAlignment(
  GitDir gitDir,
  String defaultBranch, {
  String? expectedUpstream,
}) async {
  final targetUpstream = expectedUpstream ?? 'origin/$defaultBranch';
  if (await gitDir.branchReference(defaultBranch) == null) {
    printError('Warning: Local branch "$defaultBranch" does not exist.');
    throw GitUpException(
      'Local branch does not exist.',
      exitCode: ExitCode.config.code,
    );
  }

  final upstream = await gitDir.upstreamBranch(defaultBranch);

  if (upstream == null) {
    printError(
      'Error: Local branch "$defaultBranch" has no upstream configured.',
    );
    _printUpstreamFixSuggestion(defaultBranch, targetUpstream);
    throw GitUpException(
      'Branch has no upstream.',
      exitCode: ExitCode.config.code,
    );
  }

  if (upstream != targetUpstream) {
    printError(
      'Error: Local branch "$defaultBranch" tracks "$upstream", '
      'not "$targetUpstream".',
    );
    _printUpstreamFixSuggestion(defaultBranch, targetUpstream);
    throw GitUpException(
      'Branch alignment failed.',
      exitCode: ExitCode.config.code,
    );
  }
}

void _printUpstreamFixSuggestion(String defaultBranch, String targetUpstream) {
  printError('To fix this, run:');
  printError('  git branch --set-upstream-to=$targetUpstream $defaultBranch');
}

Future<void> _runHookCommand(
  GitDir gitDir, {
  required String configKey,
  required String hookName,
  String? commandOverride,
}) async {
  final String command;
  if (commandOverride != null) {
    command = commandOverride;
  } else {
    final configResult = await gitDir.runCommand([
      'config',
      '--get',
      configKey,
    ], throwOnError: false);
    if (configResult.exitCode != 0) {
      return;
    }
    command = (configResult.stdout as String).trim();
  }

  if (command.isEmpty) {
    return;
  }

  await _runShellCommand(gitDir.path, command, hookName: hookName);
}

Future<void> _runShellCommand(
  String workingDirectory,
  String command, {
  required String hookName,
}) async {
  print(
    styleDim.wrap('Running ${hookName.toLowerCase()}-command: $command') ??
        'Running ${hookName.toLowerCase()}-command: $command',
  );

  final shell = Platform.isWindows ? 'cmd.exe' : 'sh';
  final shellArgs = Platform.isWindows ? ['/c', command] : ['-c', command];

  final process = await Process.start(
    shell,
    shellArgs,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw GitUpException(
      '$hookName-command '
      'failed with exit code $exitCode: $command',
      exitCode: exitCode,
    );
  }
}

Future<void> _cleanBranches(
  GitDir gitDir,
  String defaultBranch, {
  bool check = false,
}) async {
  await _fetchAndPrune(gitDir);
  final branches = await _categorizeBranches(gitDir, defaultBranch);
  final (:goneBranches, :activeRemoteBranches, :ghAvailable, :recentPrs) =
      await _resolveGitHubStatus(gitDir, branches);
  if (goneBranches.isEmpty) {
    print('No local branches found with deleted upstreams.');
  } else {
    print(
      styleDim.wrap(
        'Checking safety of ${goneBranches.length} branches with '
        'gone upstreams...',
      )!,
    );
  }
  final toDelete = <String>[
    for (final entry in goneBranches.entries)
      if (await _shouldDeleteBranch(
        gitDir,
        defaultBranch,
        entry.key,
        entry.value,
        ghAvailable: ghAvailable,
        recentPrs: recentPrs,
      ))
        entry.key,
  ];
  if (toDelete.isNotEmpty) {
    await _executeBranchDeletion(gitDir, goneBranches, toDelete);
  }

  if (!check) {
    if (activeRemoteBranches.isNotEmpty) {
      print(
        styleDim.wrap(
          'Tip: Run with --check to inspect active remote branches '
          'for closed PRs.',
        )!,
      );
    }
    return;
  }

  if (activeRemoteBranches.isEmpty) {
    print('No active remote branches to check.');
    return;
  }
  if (!ghAvailable) {
    printError(
      'Warning: GitHub CLI (gh) is not available or authenticated. '
      'Skipping active remote branch checks.',
    );
    return;
  }
  if (recentPrs == null) return;

  var closedHeadingPrinted = false;
  var conflictHeadingPrinted = false;
  for (final branch in activeRemoteBranches) {
    final printed = await _inspectSingleRemoteBranch(
      gitDir,
      branch,
      recentPrs,
      closedHeadingPrinted: closedHeadingPrinted,
      conflictHeadingPrinted: conflictHeadingPrinted,
    );
    closedHeadingPrinted = printed.closedHeadingPrinted;
    conflictHeadingPrinted = printed.conflictHeadingPrinted;
  }
}

Future<void> _fetchAndPrune(GitDir gitDir) async {
  print(styleDim.wrap('Fetching and pruning...') ?? 'Fetching and pruning...');
  try {
    await gitDir.fetch(prune: true);
  } catch (e) {
    printError('Warning: failed to fetch and prune: $e');
  }
}

typedef _CategorizedBranches = ({
  Map<String, String> branchShas,
  Map<String, String> goneBranches,
  List<String> activeRemoteBranches,
  List<String> noUpstreamBranches,
});

Future<_CategorizedBranches> _categorizeBranches(
  GitDir gitDir,
  String defaultBranch,
) async {
  final branchShas = <String, String>{};
  final goneBranches = <String, String>{};
  final activeRemoteBranches = <String>[];
  final noUpstreamBranches = <String>[];

  final branches = await gitDir.branchTracking();
  for (final b in branches) {
    final branchName = b.branchName;
    if (branchName == 'master' ||
        branchName == 'main' ||
        branchName == defaultBranch) {
      continue;
    }
    branchShas[branchName] = b.sha;
    if (b.isUpstreamGone) {
      goneBranches[branchName] = b.sha;
    } else if (b.upstream.isNotEmpty) {
      activeRemoteBranches.add(branchName);
    } else {
      noUpstreamBranches.add(branchName);
    }
  }

  return (
    branchShas: branchShas,
    goneBranches: goneBranches,
    activeRemoteBranches: activeRemoteBranches,
    noUpstreamBranches: noUpstreamBranches,
  );
}

typedef _ResolvedGitHubStatus = ({
  Map<String, String> goneBranches,
  List<String> activeRemoteBranches,
  bool ghAvailable,
  Map<String, PrInfo>? recentPrs,
});

Future<_ResolvedGitHubStatus> _resolveGitHubStatus(
  GitDir gitDir,
  _CategorizedBranches branches,
) async {
  final goneBranches = Map<String, String>.of(branches.goneBranches);
  final activeRemoteBranches = List<String>.of(branches.activeRemoteBranches);

  final needGh =
      goneBranches.isNotEmpty ||
      activeRemoteBranches.isNotEmpty ||
      branches.noUpstreamBranches.isNotEmpty;
  final ghAvailable = needGh && await _isGitHubCliAvailable();
  if (!ghAvailable) {
    return (
      goneBranches: goneBranches,
      activeRemoteBranches: activeRemoteBranches,
      ghAvailable: false,
      recentPrs: null,
    );
  }

  final recentPrs = await _getRecentPrsInfo();
  final toMove = <String>[];
  for (final branch in activeRemoteBranches) {
    final prInfo = recentPrs[branch];
    if (prInfo != null && prInfo.state == 'MERGED') {
      toMove.add(branch);
    }
  }

  for (final branch in toMove) {
    activeRemoteBranches.remove(branch);
    goneBranches[branch] = branches.branchShas[branch]!;
  }

  for (final branch in branches.noUpstreamBranches) {
    final prInfo = recentPrs[branch];
    if (prInfo != null &&
        (prInfo.state == 'MERGED' || prInfo.state == 'CLOSED')) {
      goneBranches[branch] = branches.branchShas[branch]!;
    }
  }

  return (
    goneBranches: goneBranches,
    activeRemoteBranches: activeRemoteBranches,
    ghAvailable: true,
    recentPrs: recentPrs,
  );
}

Future<bool> _shouldDeleteBranch(
  GitDir gitDir,
  String defaultBranch,
  String branch,
  String sha, {
  required bool ghAvailable,
  required Map<String, PrInfo>? recentPrs,
}) async {
  PrInfo? prInfo;
  if (ghAvailable) {
    prInfo = await _getPrInfoForBranch(
      gitDir,
      branch,
      cachedRecentPrs: recentPrs,
    );
  }
  final prState = prInfo?.state;
  final baseBranch = prInfo?.baseBranch;
  final headRefOid = prInfo?.headRefOid;

  final targetBranch = (baseBranch != null && baseBranch.isNotEmpty)
      ? baseBranch
      : defaultBranch;

  final targetRefs = await gitDir.resolveLookups(targetBranch);
  if (targetRefs.isEmpty) {
    targetRefs.add(targetBranch);
  }

  for (final ref in targetRefs) {
    if (await _isMergedInto(gitDir, branch, ref)) {
      return true;
    }
  }

  if (ghAvailable && prState == 'MERGED') {
    return _evaluateMergedPrWithLocalCommits(gitDir, branch, headRefOid);
  }

  printError(
    'Warning: Branch "$branch" ($sha) has a gone upstream but contains '
    'unmerged commits (relative to $targetBranch). Skipping deletion.',
  );
  return false;
}

Future<bool> _evaluateMergedPrWithLocalCommits(
  GitDir gitDir,
  String branch,
  String? headRefOid,
) async {
  final hasNewCommits =
      headRefOid != null &&
      await _hasCommitsPastHead(gitDir, headRefOid, branch);
  if (!hasNewCommits) {
    return true;
  }

  if (!isTesting && stdin.hasTerminal) {
    final prompt =
        'Branch "$branch" has a merged PR but contains local '
        'commits after PR head. Delete anyway? [y/N]: ';
    stdout.write(yellow.wrap(prompt) ?? prompt);
    final response = stdin.readLineSync()?.trim().toLowerCase();
    if (response == 'y' || response == 'yes') {
      return true;
    }
    print(
      styleDim.wrap('Skipping deletion of "$branch".') ??
          'Skipping deletion of "$branch".',
    );
    return false;
  }

  printError(
    'Warning: Branch "$branch" has a merged PR but contains '
    'local commits after PR head. Skipping deletion.',
  );
  return false;
}

Future<void> _executeBranchDeletion(
  GitDir gitDir,
  Map<String, String> goneBranches,
  List<String> toDelete,
) async {
  print('Found ${toDelete.length} branches to delete:');
  for (final branch in toDelete) {
    print('  $branch (${goneBranches[branch]})');
  }

  final worktrees = {
    for (final wt in await gitDir.worktrees())
      if (wt.branch.isNotEmpty) wt.branch: wt.path,
  };
  for (final branch in toDelete) {
    final worktreePath = worktrees[branch];
    if (worktreePath != null &&
        !await _removeCleanWorktree(gitDir, branch, worktreePath)) {
      continue;
    }

    print('Deleting $branch...');
    try {
      await gitDir.deleteBranch(branch, force: true);
      print('  Done!');
    } catch (e) {
      printError('Failed to delete $branch: $e');
    }
  }
}

Future<bool> _removeCleanWorktree(
  GitDir gitDir,
  String branch,
  String worktreePath,
) async {
  try {
    final wtGitDir = await GitDir.fromExisting(worktreePath);
    if (!await wtGitDir.isWorkingTreeClean(includeUntracked: false)) {
      printError(
        'Warning: Branch "$branch" is checked out in worktree at '
        '"$worktreePath", which has uncommitted changes. '
        'Skipping deletion.',
      );
      return false;
    }
  } catch (_) {
    // Ignore if GitDir.fromExisting fails
  }

  if (!isTesting && stdin.hasTerminal) {
    final prompt =
        'Branch "$branch" is checked out in worktree at '
        '"$worktreePath". '
        'All changes are merged and working tree is clean. '
        'Remove worktree and delete branch? [Y/n]: ';
    stdout.write(yellow.wrap(prompt) ?? prompt);
    final response = stdin.readLineSync()?.trim().toLowerCase();
    if (response == 'n' || response == 'no') {
      print(
        styleDim.wrap('Skipping deletion of "$branch".') ??
            'Skipping deletion of "$branch".',
      );
      return false;
    }
  }

  print('Removing worktree at $worktreePath...');
  try {
    await gitDir.removeWorktree(worktreePath, force: true);
    print('  Worktree removed!');
    return true;
  } catch (e) {
    printError('Failed to remove worktree at $worktreePath: $e');
    return false;
  }
}

Future<({bool closedHeadingPrinted, bool conflictHeadingPrinted})>
_inspectSingleRemoteBranch(
  GitDir gitDir,
  String branch,
  Map<String, PrInfo> recentPrs, {
  required bool closedHeadingPrinted,
  required bool conflictHeadingPrinted,
}) async {
  final prInfo = recentPrs[branch];
  if (prInfo != null &&
      prInfo.state == 'OPEN' &&
      prInfo.mergeable == 'CONFLICTING') {
    if (!conflictHeadingPrinted) {
      print('');
      const heading = 'Checking active remote branches for merge conflicts...';
      print(styleDim.wrap(heading) ?? heading);
    }
    _printConflictingBranchNotice(branch, prInfo);
    return (
      closedHeadingPrinted: closedHeadingPrinted,
      conflictHeadingPrinted: true,
    );
  }

  if (prInfo == null ||
      (prInfo.state != 'MERGED' && prInfo.state != 'CLOSED') ||
      !await _hasRemoteBranch(gitDir, branch)) {
    return (
      closedHeadingPrinted: closedHeadingPrinted,
      conflictHeadingPrinted: conflictHeadingPrinted,
    );
  }

  if (!closedHeadingPrinted) {
    print('');
    const heading = 'Checking active remote branches for closed PRs...';
    print(styleDim.wrap(heading) ?? heading);
  }
  _printClosedRemoteBranchNotice(branch, prInfo);
  return (
    closedHeadingPrinted: true,
    conflictHeadingPrinted: conflictHeadingPrinted,
  );
}

void _printConflictingBranchNotice(String branch, PrInfo prInfo) {
  final url = prInfo.url ?? '';
  final prLabel = prInfo.number != null ? '#${prInfo.number}' : '';
  final branchLabel = styleBold.wrap(branch) ?? branch;
  final baseLabel = prInfo.baseBranch.isNotEmpty ? prInfo.baseBranch : 'main';
  final warnBadge = red.wrap('⚠️ MERGE CONFLICT') ?? '⚠️ MERGE CONFLICT';
  print(
    '$warnBadge: PR $prLabel for branch "$branchLabel" has merge conflicts '
    'with "$baseLabel".\n'
    '  URL:     $url\n'
    '  Resolve: git fetch origin $baseLabel && git merge origin/$baseLabel',
  );
}

void _printClosedRemoteBranchNotice(String branch, PrInfo prInfo) {
  final url = prInfo.url ?? '';
  final prLabel = prInfo.number != null ? '#${prInfo.number}' : '';
  final branchLabel = styleBold.wrap(branch) ?? branch;
  final link = '\x1B]8;;$url\x1B\\Click here\x1B]8;;\x1B\\';
  print(
    'PR $prLabel for branch "$branchLabel" is closed, '
    'but the remote branch still exists.\n'
    '  $link to delete it: $url',
  );
}

/// Exception thrown by `git-up` operations.
///
/// Contains a user-friendly [message] and an suggested [exitCode].
class GitUpException(final String message, {final int exitCode = 1})
    implements Exception {
  @override
  String toString() => message;
}

/// Checks if [branchName] is merged into [targetBranch].
///
/// A branch is merged if:
/// 1. It is an ancestor of [targetBranch] (standard merge or rebase).
/// 2. Or, a three-way merge of [branchName] into [targetBranch] results in a
///    tree identical to [targetBranch] (squash merge).
Future<bool> _isMergedInto(
  GitDir gitDir,
  String branchName,
  String targetBranch,
) async {
  if (await gitDir.isAncestor(branchName, targetBranch)) return true;

  if (await _matchesTargetCommitTree(gitDir, branchName, targetBranch)) {
    return true;
  }

  return _matchesTrialMergeTree(gitDir, branchName, targetBranch);
}

Future<bool> _matchesTargetCommitTree(
  GitDir gitDir,
  String branchName,
  String targetBranch,
) async {
  try {
    final branchTreeResult = await gitDir.runCommand([
      'rev-parse',
      '$branchName^{tree}',
    ], throwOnError: false);
    if (branchTreeResult.exitCode != 0) return false;
    final branchTree = (branchTreeResult.stdout as String).trim();

    final targetTreesResult = await gitDir.runCommand([
      'log',
      targetBranch,
      '--format=%T',
      '-n',
      '1000',
    ], throwOnError: false);
    if (targetTreesResult.exitCode != 0) return false;

    return (targetTreesResult.stdout as String)
        .split('\n')
        .contains(branchTree);
  } catch (_) {
    return false;
  }
}

Future<bool> _matchesTrialMergeTree(
  GitDir gitDir,
  String branchName,
  String targetBranch,
) async {
  try {
    final targetTreeResult = await gitDir.runCommand([
      'rev-parse',
      '$targetBranch^{tree}',
    ], throwOnError: false);
    if (targetTreeResult.exitCode != 0) return false;
    final targetTree = (targetTreeResult.stdout as String).trim();

    final mergeTreeResult = await gitDir.runCommand([
      'merge-tree',
      '--write-tree',
      targetBranch,
      branchName,
    ], throwOnError: false);
    if (mergeTreeResult.exitCode != 0) return false;

    return (mergeTreeResult.stdout as String).trim() == targetTree;
  } catch (_) {
    return false;
  }
}

/// Checks if the `gh` CLI is available and authenticated.
Future<bool> _isGitHubCliAvailable() async {
  if (mockGhAvailableForTesting) return true;
  if (mockGhUnavailableForTesting) return false;
  try {
    final result = await Process.run('gh', ['auth', 'status']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Checks if a remote-tracking branch named [branchName] exists for `origin`.
Future<bool> _hasRemoteBranch(GitDir gitDir, String branchName) async {
  final result = await gitDir.runCommand([
    'show-ref',
    '--verify',
    'refs/remotes/origin/$branchName',
  ], throwOnError: false);
  return result.exitCode == 0;
}

/// Gets the PR number stored in the local git config for [branchName], if any.
Future<int?> _getLocalPrNumber(GitDir gitDir, String branchName) async {
  final result = await gitDir.runCommand([
    'config',
    '--get',
    'branch.$branchName.gh-pr-number',
  ], throwOnError: false);
  if (result.exitCode != 0) return null;
  final output = (result.stdout as String).trim();
  if (output.isEmpty) return null;
  return int.tryParse(output);
}

Future<PrInfo?> _getPrInfo(String target) async {
  try {
    final result = await Process.run('gh', [
      'pr',
      'view',
      target,
      '--json',
      'state,baseRefName,headRefOid,url,number,mergeable',
    ]);
    if (result.exitCode == 0) {
      final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      return (
        state: data['state'] as String? ?? '',
        baseBranch: data['baseRefName'] as String? ?? '',
        headRefOid: data['headRefOid'] as String?,
        url: data['url'] as String?,
        number: data['number'] as int?,
        mergeable: data['mergeable'] as String?,
      );
    }
  } catch (_) {
    // Ignore and return null
  }
  return null;
}

/// Resolves PR info for [branchName] by checking local git config PR number,
/// falling back to [cachedRecentPrs], or querying GitHub directly.
Future<PrInfo?> _getPrInfoForBranch(
  GitDir gitDir,
  String branchName, {
  Map<String, PrInfo>? cachedRecentPrs,
}) async {
  final prNumber = await _getLocalPrNumber(gitDir, branchName);
  if (prNumber != null) {
    final prInfo = await _getPrInfo(prNumber.toString());
    if (prInfo != null) return prInfo;
  }

  final cachedPr = cachedRecentPrs?[branchName];
  if (cachedPr != null) return cachedPr;

  return _getPrInfo(branchName);
}

/// Retrieves the details of recent PRs in the repository.
Future<Map<String, PrInfo>> _getRecentPrsInfo({int limit = 100}) async {
  if (mockRecentPrsForTesting != null) {
    return mockRecentPrsForTesting!;
  }
  final prs = <String, PrInfo>{};
  try {
    final result = await Process.run('gh', [
      'pr',
      'list',
      '--state',
      'all',
      '--author',
      '@me',
      '--limit',
      limit.toString(),
      '--json',
      'headRefName,state,url,number,baseRefName,headRefOid,mergeable',
    ]);
    if (result.exitCode != 0) return prs;

    final list = jsonDecode(result.stdout as String) as List<dynamic>;
    for (final item in list) {
      final parsed = _parsePrInfoEntry(item);
      if (parsed != null) {
        prs[parsed.$1] = parsed.$2;
      }
    }
  } catch (_) {
    // Ignore and return empty map
  }
  return prs;
}

(String, PrInfo)? _parsePrInfoEntry(Object? item) => switch (item) {
  {
    'headRefName': final String head,
    'state': final String state,
    'url': final String url,
    'number': final int number,
    'baseRefName': final String baseBranch,
    'headRefOid': final Object? headRefOid,
    'mergeable': final Object? mergeable,
  } =>
    (
      head,
      (
        state: state,
        url: url,
        number: number,
        baseBranch: baseBranch,
        headRefOid: headRefOid is String ? headRefOid : null,
        mergeable: mergeable is String ? mergeable : null,
      ),
    ),
  _ => null,
};

/// Checks if [branchName] has commits that are not present in [headRefOid].
Future<bool> _hasCommitsPastHead(
  GitDir gitDir,
  String headRefOid,
  String branchName,
) async {
  final result = await gitDir.runCommand([
    'log',
    '$headRefOid..$branchName',
    '--oneline',
  ], throwOnError: false);
  if (result.exitCode != 0) return true;
  return (result.stdout as String).trim().isNotEmpty;
}

/// Resolves the given [branchName] to its local ref and/or its upstream ref if
/// they exist.
Future<Set<String>> _resolveLookups(GitDir gitDir, String branchName) async {
  if (branchName.isEmpty) return const <String>{};
  final refs = <String>{};

  final upstreamResult = await gitDir.runCommand([
    'rev-parse',
    '--symbolic-full-name',
    '$branchName@{u}',
  ], throwOnError: false);
  if (upstreamResult.exitCode == 0) {
    refs.add((upstreamResult.stdout as String).trim());
  }

  final localResult = await gitDir.runCommand([
    'rev-parse',
    '--symbolic-full-name',
    branchName,
  ], throwOnError: false);
  if (localResult.exitCode == 0) {
    refs.add((localResult.stdout as String).trim());
  }

  final remotesResult = await gitDir.runCommand([
    'for-each-ref',
    '--format=%(refname)',
    'refs/remotes/*/$branchName',
  ], throwOnError: false);
  if (remotesResult.exitCode == 0) {
    final lines = LineSplitter.split(remotesResult.stdout as String);
    for (final line in lines) {
      final ref = line.trim();
      if (ref.isNotEmpty) {
        refs.add(ref);
      }
    }
  }

  return refs;
}

Future<String?> _getMainWorktreePath(GitDir gitDir) async {
  final wts = await gitDir.worktrees();
  for (final wt in wts) {
    if (!wt.isBare) return wt.path;
  }
  return null;
}

extension GitDirUpExtensions on GitDir {
  /// Resolves the given [branchName] to its local ref and/or its upstream ref if
  /// they exist.
  Future<Set<String>> resolveLookups(String branchName) =>
      _resolveLookups(this, branchName);

  /// Returns the path of the primary (main) worktree in the repository.
  Future<String?> getMainWorktreePath() => _getMainWorktreePath(this);
}
