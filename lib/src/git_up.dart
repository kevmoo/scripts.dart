import 'dart:io';

import 'package:git/git.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart';

import 'git_extensions.dart';
import 'testable_print.dart';

/// Safely switches to and updates the default branch of a Git repository.
///
/// This function orchestrates the following steps:
/// 1. Finds the Git root directory.
/// 2. Determines the default branch (sniffing for `origin/HEAD` or fallback
///    to `main`/`master`).
/// 3. Verifies that the local branch exists and tracks the correct upstream.
/// 4. Checks out the default branch.
/// 5. Pulls updates with `--ff-only`.
///
/// Throws a [GitUpException] if any step fails with a clear message and
/// exit code.
///
/// [workingDirectory] specifies the directory to start searching for the
/// Git root. Defaults to [Directory.current]`.path`.
Future<void> gitUp({String? workingDirectory, bool check = false}) async {
  workingDirectory ??= Directory.current.path;

  final gitDir = await getGitDir(workingDirectory);

  if (await gitDir.isDirty()) {
    printError('Please commit or stash your changes and try again.');
    throw GitUpException('Working tree is dirty.');
  }

  await _runHookCommand(gitDir, configKey: 'git-up.before', hookName: 'Before');

  // 1. Determine Default Branch
  final defaultBranch = await getDefaultBranch(gitDir);

  final boldBranch = styleBold.wrap(defaultBranch) ?? defaultBranch;
  print(
    styleDim.wrap('Default branch: $boldBranch') ??
        'Default branch: $boldBranch',
  );

  // 2. Verify Alignment
  await verifyAlignment(gitDir, defaultBranch);

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

  await _cleanBranches(gitDir, defaultBranch, check: check);

  await _runHookCommand(gitDir, configKey: 'git-up.post', hookName: 'Post');
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
Future<GitDir> getGitDir(String workingDirectory) async {
  try {
    return await GitDirExtensions.fromCurrentDirectory(workingDirectory);
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
    final output = (revParseResult.stdout as String).trim();
    if (output.startsWith('origin/')) {
      return output.substring('origin/'.length);
    }
    return output;
  }

  // If origin/HEAD is missing, we can use the extension to see if it CAN sniff a branch,
  // so we can give a better error message (matching original behavior).
  final sniffedBranch = await gitDir.getDefaultBranch();

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
/// 3. The upstream is `origin/[defaultBranch]`.
///
/// Throws a [GitUpException] with specific advice if any check fails.
///
/// [gitDir] is the Git repository.
/// [defaultBranch] is the name of the default branch to verify.
Future<void> verifyAlignment(GitDir gitDir, String defaultBranch) async {
  if (!await gitDir.hasBranch(defaultBranch)) {
    printError('Warning: Local branch "$defaultBranch" does not exist.');
    throw GitUpException(
      'Local branch does not exist.',
      exitCode: ExitCode.config.code,
    );
  }

  final upstream = await gitDir.getUpstream(defaultBranch);

  if (upstream == null) {
    printError(
      'Error: Local branch "$defaultBranch" has no upstream configured.',
    );
    _printUpstreamFixSuggestion(defaultBranch);
    throw GitUpException(
      'Branch has no upstream.',
      exitCode: ExitCode.config.code,
    );
  }

  if (upstream != 'origin/$defaultBranch') {
    printError(
      'Error: Local branch "$defaultBranch" tracks "$upstream", not "origin/$defaultBranch".',
    );
    _printUpstreamFixSuggestion(defaultBranch);
    throw GitUpException(
      'Branch alignment failed.',
      exitCode: ExitCode.config.code,
    );
  }
}

void _printUpstreamFixSuggestion(String defaultBranch) {
  printError('To fix this, run:');
  printError(
    '  git branch --set-upstream-to=origin/$defaultBranch $defaultBranch',
  );
}

Future<void> _runHookCommand(
  GitDir gitDir, {
  required String configKey,
  required String hookName,
}) async {
  final configResult = await gitDir.runCommand([
    'config',
    '--get',
    configKey,
  ], throwOnError: false);

  if (configResult.exitCode != 0) {
    return;
  }

  final command = (configResult.stdout as String).trim();
  if (command.isEmpty) {
    return;
  }

  print(
    styleDim.wrap('Running ${hookName.toLowerCase()}-command: $command') ??
        'Running ${hookName.toLowerCase()}-command: $command',
  );

  final shell = Platform.isWindows ? 'cmd.exe' : 'sh';
  final shellArgs = Platform.isWindows ? ['/c', command] : ['-c', command];

  final process = await Process.start(
    shell,
    shellArgs,
    workingDirectory: gitDir.path,
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
}) => _CleanBranchesRunner(gitDir, defaultBranch, check).run();

class _CleanBranchesRunner(
  final GitDir _gitDir,
  final String _defaultBranch,
  final bool _check,
) {
  final _branchShas = <String, String>{}; // name -> sha
  final _goneBranches = <String, String>{}; // name -> sha
  final _activeRemoteBranches = <String>[]; // name
  final _noUpstreamBranches = <String>[]; // name

  bool _ghAvailable = false;
  Map<String, PrInfo>? _recentPrs;

  Future<void> run() async {
    await _fetchAndPrune();
    await _categorizeBranches();
    await _resolveGitHubStatus();
    await _processGoneBranches();
    await _inspectActiveRemoteBranches();
  }

  Future<void> _fetchAndPrune() async {
    print(
      styleDim.wrap('Fetching and pruning...') ?? 'Fetching and pruning...',
    );
    try {
      await _gitDir.fetch(prune: true);
    } catch (e) {
      printError('Warning: failed to fetch and prune: $e');
    }
  }

  Future<void> _categorizeBranches() async {
    final branchesStatus = await _gitDir.getBranchesStatus();
    for (final MapEntry(
          key: branchName,
          value: (:sha, :upstream, :isUpstreamGone),
        )
        in branchesStatus.entries) {
      if (branchName == 'master' ||
          branchName == 'main' ||
          branchName == _defaultBranch) {
        continue;
      }
      _branchShas[branchName] = sha;
      if (isUpstreamGone) {
        _goneBranches[branchName] = sha;
      } else if (upstream.isNotEmpty) {
        _activeRemoteBranches.add(branchName);
      } else {
        _noUpstreamBranches.add(branchName);
      }
    }
  }

  Future<void> _resolveGitHubStatus() async {
    final needGh =
        _goneBranches.isNotEmpty ||
        _activeRemoteBranches.isNotEmpty ||
        _noUpstreamBranches.isNotEmpty;
    _ghAvailable = needGh && await _gitDir.isGitHubCliAvailable();
    if (!_ghAvailable) return;

    _recentPrs = await _gitDir.getRecentPrsInfo();
    final toMove = <String>[];
    for (final branch in _activeRemoteBranches) {
      final prInfo = _recentPrs?[branch];
      if (prInfo != null && prInfo.state == 'MERGED') {
        toMove.add(branch);
      }
    }

    for (final branch in toMove) {
      _activeRemoteBranches.remove(branch);
      _goneBranches[branch] = _branchShas[branch]!;
    }

    for (final branch in _noUpstreamBranches) {
      final prInfo = _recentPrs?[branch];
      if (prInfo != null &&
          (prInfo.state == 'MERGED' || prInfo.state == 'CLOSED')) {
        _goneBranches[branch] = _branchShas[branch]!;
      }
    }
  }

  Future<void> _processGoneBranches() async {
    if (_goneBranches.isEmpty) {
      print('No local branches found with deleted upstreams.');
      return;
    }

    print(
      styleDim.wrap(
            'Checking safety of ${_goneBranches.length} branches with '
            'gone upstreams...',
          ) ??
          'Checking safety of ${_goneBranches.length} branches with '
              'gone upstreams...',
    );

    final toDelete = <String>[];
    for (final entry in _goneBranches.entries) {
      if (await _shouldDeleteBranch(entry.key, entry.value)) {
        toDelete.add(entry.key);
      }
    }

    if (toDelete.isNotEmpty) {
      await _executeBranchDeletion(toDelete);
    }
  }

  Future<bool> _shouldDeleteBranch(String branch, String sha) async {
    PrInfo? prInfo;
    if (_ghAvailable) {
      prInfo = await _gitDir.getPrInfoForBranch(
        branch,
        cachedRecentPrs: _recentPrs,
      );
    }
    final prState = prInfo?.state;
    final baseBranch = prInfo?.baseBranch;
    final headRefOid = prInfo?.headRefOid;

    final targetBranch = (baseBranch != null && baseBranch.isNotEmpty)
        ? baseBranch
        : _defaultBranch;

    final targetRefs = await _gitDir.resolveLookups(targetBranch);
    if (targetRefs.isEmpty) {
      targetRefs.add(targetBranch);
    }

    for (final ref in targetRefs) {
      if (await _gitDir.isMergedInto(branch, ref)) {
        return true;
      }
    }

    if (_ghAvailable && prState == 'MERGED') {
      return _evaluateMergedPrWithLocalCommits(branch, headRefOid);
    }

    printError(
      'Warning: Branch "$branch" ($sha) has a gone upstream but contains '
      'unmerged commits (relative to $targetBranch). Skipping deletion.',
    );
    return false;
  }

  Future<bool> _evaluateMergedPrWithLocalCommits(
    String branch,
    String? headRefOid,
  ) async {
    final hasNewCommits =
        headRefOid != null &&
        await _gitDir.hasCommitsPastHead(headRefOid, branch);
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

  Future<void> _executeBranchDeletion(List<String> toDelete) async {
    print('Found ${toDelete.length} branches to delete:');
    for (final branch in toDelete) {
      print('  $branch (${_goneBranches[branch]})');
    }

    final worktrees = await _gitDir.getWorktrees();
    for (final branch in toDelete) {
      final worktreePath = worktrees[branch];
      if (worktreePath != null &&
          !await _removeCleanWorktree(branch, worktreePath)) {
        continue;
      }

      print('Deleting $branch...');
      try {
        await _gitDir.deleteBranch(branch, force: true);
        print('  Done!');
      } catch (e) {
        printError('Failed to delete $branch: $e');
      }
    }
  }

  Future<bool> _removeCleanWorktree(String branch, String worktreePath) async {
    try {
      final wtGitDir = await GitDir.fromExisting(worktreePath);
      if (await wtGitDir.isDirty()) {
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
      await _gitDir.removeWorktree(worktreePath, force: true);
      print('  Worktree removed!');
      return true;
    } catch (e) {
      printError('Failed to remove worktree at $worktreePath: $e');
      return false;
    }
  }

  Future<void> _inspectActiveRemoteBranches() async {
    if (!_check) {
      if (_activeRemoteBranches.isNotEmpty) {
        print(
          styleDim.wrap(
                'Tip: Run with --check to inspect active remote branches '
                'for closed PRs.',
              ) ??
              'Tip: Run with --check to inspect active remote branches '
                  'for closed PRs.',
        );
      }
      return;
    }

    if (_activeRemoteBranches.isEmpty) {
      print('No active remote branches to check.');
      return;
    }
    if (!_ghAvailable) {
      printError(
        'Warning: GitHub CLI (gh) is not available or authenticated. '
        'Skipping active remote branch checks.',
      );
      return;
    }
    if (_recentPrs == null) return;

    var headingPrinted = false;
    for (final branch in _activeRemoteBranches) {
      if (!await _hasClosedRemoteBranch(branch)) continue;

      if (!headingPrinted) {
        print('');
        print(
          styleDim.wrap('Checking active remote branches for closed PRs...') ??
              'Checking active remote branches for closed PRs...',
        );
        headingPrinted = true;
      }

      _printClosedRemoteBranchNotice(branch, _recentPrs![branch]!);
    }
  }

  Future<bool> _hasClosedRemoteBranch(String branch) async {
    final prInfo = _recentPrs?[branch];
    if (prInfo == null) return false;
    if (prInfo.state != 'MERGED' && prInfo.state != 'CLOSED') return false;
    return _gitDir.hasRemoteBranch(branch);
  }

  void _printClosedRemoteBranchNotice(String branch, PrInfo prInfo) {
    final url = prInfo.url ?? '';
    final prLabel = prInfo.number != null ? '#${prInfo.number}' : '';
    final branchLabel = styleBold.wrap(branch) ?? branch;
    final link = _hyperlink(url, 'Click here');
    print(
      'PR $prLabel for branch "$branchLabel" is closed, '
      'but the remote branch still exists.\n'
      '  $link to delete it: $url',
    );
  }
}

String _hyperlink(String url, String text) =>
    '\x1B]8;;$url\x1B\\$text\x1B]8;;\x1B\\';

/// Exception thrown by `git-up` operations.
///
/// Contains a user-friendly [message] and an suggested [exitCode].
class GitUpException(final String message, {final int exitCode = 1})
    implements Exception {
  @override
  String toString() => message;
}
