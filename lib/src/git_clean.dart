import 'dart:io';

import 'package:git/git.dart';

import 'git_extensions.dart';
import 'testable_print.dart';

Future<void> gitClean(GitDir gitDir) async {
  // 2. Fetch with prune to update remote tracking branches
  print('Fetching and pruning...');
  try {
    await gitDir.fetch(prune: true);
  } on ProcessException catch (e) {
    throw GitCleanException('Error fetching: ${e.message}');
  }

  // 3a. Get current branch
  final currentBranch = (await gitDir.currentBranch()).branchName;
  print('Current branch: $currentBranch');

  // 3b. Identify "primary" branch (main or master)
  String? primaryBranch;
  for (final branch in ['main', 'master']) {
    if (await gitDir.hasBranch(branch)) {
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
  final branchesStatus = await gitDir.getBranchesStatus();

  // Key: branch name, Value: SHA
  final branchesToDelete = <String, String>{};
  var currentIsGone = false;

  for (final MapEntry(key: branchName, value: (:sha, :isUpstreamGone))
      in branchesStatus.entries) {
    if (isUpstreamGone) {
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
    final mergeResult = await gitDir.fastForwardMerge();

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
  } else {
    if (primaryBranch != null) {
      print(
        'Current branch ($newCurrentBranch) is not the primary branch '
        '($primaryBranch). Skipping fast-forward.',
      );
    } else {
      print('No primary branch found. Skipping fast-forward.');
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
    try {
      await gitDir.deleteBranch(branch, force: true);
      print('  Done!');
    } on ProcessException catch (e) {
      printError('Failed to delete $branch: ${e.message}');
      // We log but don't throw here to allow other deletions to proceed
    }
  }
}

class GitCleanException(final String message) implements Exception {
  @override
  String toString() => message;
}
