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
}) async {
  print(styleDim.wrap('Fetching and pruning...') ?? 'Fetching and pruning...');
  try {
    await gitDir.fetch(prune: true);
  } catch (e) {
    printError('Warning: failed to fetch and prune: $e');
  }

  final branchesStatus = await gitDir.getBranchesStatus();
  final goneBranches = <String, String>{}; // name -> sha
  final activeRemoteBranches = <String>[]; // name
  final noUpstreamBranches = <String>[]; // name

  for (final MapEntry(
        key: branchName,
        value: (:sha, :upstream, :isUpstreamGone),
      )
      in branchesStatus.entries) {
    if (branchName == 'master' ||
        branchName == 'main' ||
        branchName == defaultBranch) {
      continue;
    }

    if (isUpstreamGone) {
      goneBranches[branchName] = sha;
    } else if (upstream.isNotEmpty) {
      activeRemoteBranches.add(branchName);
    } else {
      noUpstreamBranches.add(branchName);
    }
  }

  // Only check gh if we actually need to (either we have gone branches,
  // we have active remote branches that might have been merged,
  // or we have no-upstream branches that might have a merged/closed PR).
  final needGh =
      goneBranches.isNotEmpty ||
      activeRemoteBranches.isNotEmpty ||
      noUpstreamBranches.isNotEmpty;

  final ghAvailable = needGh && await gitDir.isGitHubCliAvailable();
  Map<String, ({String state, String url, int number, String baseBranch})>?
  recentPrs;
  if (ghAvailable) {
    recentPrs = await gitDir.getRecentPrsInfo();

    final toMove = <String>[];
    for (final branch in activeRemoteBranches) {
      final prInfo = recentPrs[branch];
      if (prInfo != null && prInfo.state == 'MERGED') {
        toMove.add(branch);
      }
    }

    for (final branch in toMove) {
      activeRemoteBranches.remove(branch);
      goneBranches[branch] = branchesStatus[branch]!.sha;
    }

    for (final branch in noUpstreamBranches) {
      final prInfo = recentPrs[branch];
      if (prInfo != null &&
          (prInfo.state == 'MERGED' || prInfo.state == 'CLOSED')) {
        goneBranches[branch] = branchesStatus[branch]!.sha;
      }
    }
  }

  if (goneBranches.isEmpty) {
    print('No local branches found with deleted upstreams.');
  } else {
    print(
      styleDim.wrap(
            'Checking safety of ${goneBranches.length} branches with '
            'gone upstreams...',
          ) ??
          'Checking safety of ${goneBranches.length} branches with '
              'gone upstreams...',
    );

    final toDelete = <String>[];

    for (final entry in goneBranches.entries) {
      final branch = entry.key;
      final sha = entry.value;

      // Determine the PR info first if GH is available, so we know the target
      // base branch!
      String? prState;
      String? baseBranch;
      if (ghAvailable) {
        final prNumber = await gitDir.getLocalPrNumber(branch);
        if (prNumber != null) {
          final prInfo = await gitDir.getPrInfoByNumber(prNumber);
          prState = prInfo?.state;
          baseBranch = prInfo?.baseBranch;
        } else {
          final cachedPr = recentPrs?[branch];
          if (cachedPr != null) {
            prState = cachedPr.state;
            baseBranch = cachedPr.baseBranch;
          } else {
            final prInfo = await gitDir.getPrInfoByBranch(branch);
            prState = prInfo?.state;
            baseBranch = prInfo?.baseBranch;
          }
        }
      }

      final targetBranch = (baseBranch != null && baseBranch.isNotEmpty)
          ? baseBranch
          : defaultBranch;

      // Resolve lookups for the target branch (e.g. targetBranch@{u} and
      // targetBranch)
      final targetRefs = await gitDir.resolveLookups(targetBranch);
      if (targetRefs.isEmpty) {
        // If we can't resolve targetRefs (e.g. base branch doesn't exist locally/remotely),
        // fallback to using targetBranch as-is (which will likely fail safely).
        targetRefs.add(targetBranch);
      }

      // Check if merged into ANY of the target refs
      var isMerged = false;
      for (final ref in targetRefs) {
        if (await gitDir.isMergedInto(branch, ref)) {
          isMerged = true;
          break;
        }
      }

      if (isMerged) {
        toDelete.add(branch);
        continue;
      }

      // Tier 2 & 3: GitHub Checks (if available)
      if (ghAvailable) {
        if (prState == 'MERGED') {
          // PR is merged, but we have unmerged local commits!
          if (stdin.hasTerminal) {
            final prompt =
                'Branch "$branch" has a merged PR but contains unmerged '
                'local commits (relative to $targetBranch). Delete anyway? [y/N]: ';
            stdout.write(yellow.wrap(prompt) ?? prompt);
            final response = stdin.readLineSync()?.trim().toLowerCase();
            if (response == 'y' || response == 'yes') {
              toDelete.add(branch);
            } else {
              print(
                styleDim.wrap('Skipping deletion of "$branch".') ??
                    'Skipping deletion of "$branch".',
              );
            }
          } else {
            printError(
              'Warning: Branch "$branch" has a merged PR but contains '
              'unmerged local commits (relative to $targetBranch). '
              'Skipping deletion.',
            );
          }
          continue;
        }
      }

      // If we reach here, it's not merged and not approved for deletion
      printError(
        'Warning: Branch "$branch" ($sha) has a gone upstream but contains '
        'unmerged commits (relative to $targetBranch). Skipping deletion.',
      );
    }

    if (toDelete.isNotEmpty) {
      print('Found ${toDelete.length} branches to delete:');
      for (final branch in toDelete) {
        print('  $branch (${goneBranches[branch]})');
      }

      for (final branch in toDelete) {
        print('Deleting $branch...');
        try {
          await gitDir.deleteBranch(branch, force: true);
          print('  Done!');
        } catch (e) {
          printError('Failed to delete $branch: $e');
        }
      }
    }
  }

  // Check active remote branches for closed PRs (only if check is enabled!)
  if (check) {
    if (activeRemoteBranches.isEmpty) {
      print('No active remote branches to check.');
    } else if (!ghAvailable) {
      printError(
        'Warning: GitHub CLI (gh) is not available or authenticated. '
        'Skipping active remote branch checks.',
      );
    } else if (recentPrs != null) {
      var headingPrinted = false;

      for (final branch in activeRemoteBranches) {
        // Optimize: Only check branches present in the cached recent PRs map.
        // This avoids making slow, sequential network calls for old/unrelated branches.
        final prInfo = recentPrs[branch];

        if (prInfo != null &&
            (prInfo.state == 'MERGED' || prInfo.state == 'CLOSED')) {
          if (await gitDir.hasRemoteBranch(branch)) {
            if (!headingPrinted) {
              print('');
              print(
                styleDim.wrap(
                      'Checking active remote branches for closed PRs...',
                    ) ??
                    'Checking active remote branches for closed PRs...',
              );
              headingPrinted = true;
            }

            final prLabel = '#${prInfo.number}';
            final branchLabel = styleBold.wrap(branch) ?? branch;
            final link = _hyperlink(prInfo.url, 'Click here');
            print(
              'PR $prLabel for branch "$branchLabel" is closed, '
              'but the remote branch still exists.\n'
              '  $link to delete it: ${prInfo.url}',
            );
          }
        }
      }
    }
  } else {
    // Print a subtle tip to remind the user about the feature!
    if (activeRemoteBranches.isNotEmpty) {
      print(
        styleDim.wrap(
              'Tip: Run with --check to inspect active remote branches '
              'for closed PRs.',
            ) ??
            'Tip: Run with --check to inspect active remote branches '
                'for closed PRs.',
      );
    }
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
