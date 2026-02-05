import 'dart:convert';

import 'package:git/git.dart';

import 'util.dart';

Future<void> clean(GitDir gitDir) async {
  // 2. Fetch with prune to update remote tracking branches
  print('Fetching and pruning...');
  final pr = await gitDir.runCommand(['fetch', '--prune'], throwOnError: false);
  if (pr.exitCode != 0) {
    throw GitCleanException('Error fetching: ${pr.stderr}');
  }

  // 3a. Get current branch
  final currentBranchResult = await gitDir.runCommand([
    'branch',
    '--show-current',
  ], throwOnError: false);
  if (currentBranchResult.exitCode != 0) {
    throw GitCleanException(
      'Error getting current branch: ${currentBranchResult.stderr}',
    );
  }
  final currentBranch = (currentBranchResult.stdout as String).trim();
  print('Current branch: $currentBranch');

  // 3b. Identify "primary" branch (main or master)
  String? primaryBranch;
  for (final branch in ['main', 'master']) {
    final result = await gitDir.runCommand([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/$branch',
    ], throwOnError: false);
    if (result.exitCode == 0) {
      primaryBranch = branch;
      break;
    }
  }

  if (primaryBranch != null) {
    print('Primary branch identified as: $primaryBranch');
  } else {
    print('Could not find "main" or "master" branch.');
  }

  // 3c. Get all branches and their upstream status
  // %(refname:short) gives the branch name (e.g. 'main')
  // %(upstream:track) gives '[gone]' if the upstream is missing
  // %(objectname:short) gives the standard 7-char SHA
  final result = await gitDir.runCommand([
    'for-each-ref',
    '--format=%(refname:short) %(upstream:track) %(objectname:short)',
    'refs/heads',
  ], throwOnError: false);

  if (result.exitCode != 0) {
    throw GitCleanException('Error listing branches: ${result.stderr}');
  }

  // Key: branch name, Value: SHA
  final branchesToDelete = <String, String>{};
  final lines = LineSplitter.split(result.stdout as String);

  var currentIsGone = false;

  for (final line in lines) {
    // line format: "branchname [gone] sha"
    // or "branchname  sha" (if no upstream or up-to-date, note the double
    // space if track is empty)
    // or "branchname [ahead 1] sha" etc.

    // Use `indexOf` and `lastIndexOf` for more robust parsing of the format:
    // "%(refname:short) %(upstream:track) %(objectname:short)"
    final firstSpace = line.indexOf(' ');
    final lastSpace = line.lastIndexOf(' ');

    if (firstSpace != -1 &&
        lastSpace > firstSpace &&
        line.substring(firstSpace + 1, lastSpace).trim() == '[gone]') {
      final branchName = line.substring(0, firstSpace);
      final sha = line.substring(lastSpace + 1);

      if (branchName == 'master' || branchName == 'main') {
        print('Skipping $branchName despite it being marked as [gone].');
        continue;
      }

      if (branchName == currentBranch) {
        currentIsGone = true;
      }

      branchesToDelete[branchName] = sha;
    }
  }

  if (currentIsGone) {
    if (primaryBranch != null) {
      print(
        'Current branch $currentBranch is gone. Switching to $primaryBranch...',
      );
      final checkout = await gitDir.runCommand([
        'checkout',
        primaryBranch,
      ], throwOnError: false);
      if (checkout.exitCode != 0) {
        throw GitCleanException(
          'Error switching to $primaryBranch: ${checkout.stderr}',
        );
      }
      // Now on primary branch, we can proceed to delete the old current branch
    } else {
      print(
        'Current branch $currentBranch is gone, but no primary branch found '
        'to switch to.',
      );
      print('Skipping deletion of current branch.');
      branchesToDelete.remove(currentBranch);
    }
  } else if (branchesToDelete.containsKey(currentBranch)) {
    // This case shouldn't be reached if logic is consistent, but safety net:
    branchesToDelete.remove(currentBranch);
  }

  // If we switched to primary branch (or were already there), check if we can
  // ff-merge. We only do this if we are cleanly on the primary branch and it
  // has an upstream.
  final newCurrentBranch = currentIsGone ? primaryBranch : currentBranch;
  if (newCurrentBranch != null && newCurrentBranch == primaryBranch) {
    // We are on primary branch. Let's try to git merge --ff-only @{u}
    // We don't want to crash if it fails, just try it.
    print('Attempting to fast-forward $primaryBranch...');
    final mergeResult = await gitDir.runCommand([
      'merge',
      '--ff-only',
      '@{u}',
    ], throwOnError: false);

    if (mergeResult.exitCode == 0) {
      if ((mergeResult.stdout as String).contains('Already up to date')) {
        print('$primaryBranch is already up to date.');
      } else {
        print('Fast-forwarded $primaryBranch.');
      }
    } else {
      // The merge failed. This is not a critical error for this script's
      // main purpose, so we don't throw. We can print stderr as a warning.
      final stderr = (mergeResult.stderr as String).trim();
      if (stderr.isNotEmpty) {
        printError('Could not fast-forward $primaryBranch: $stderr');
      }
    }
  }

  if (branchesToDelete.isEmpty) {
    print('No local branches found with deleted upstreams.');
    return;
  }

  print('Found ${branchesToDelete.length} branches to delete:');
  branchesToDelete.forEach((branch, sha) {
    print('  $branch ($sha)');
  });

  // 4. Delete the branches
  for (final branch in branchesToDelete.keys) {
    print('Deleting $branch...');
    final delResult = await gitDir.runCommand([
      'branch',
      '-D',
      branch,
    ], throwOnError: false);
    if (delResult.exitCode != 0) {
      printError('Failed to delete $branch: ${delResult.stderr}');
      // We log but don't throw here to allow other deletions to proceed
    } else {
      print('Deleted $branch');
    }
  }
}

class GitCleanException implements Exception {
  final String message;
  GitCleanException(this.message);
  @override
  String toString() => message;
}
