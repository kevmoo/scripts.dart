import 'dart:convert';

import 'package:git/git.dart';

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
  final result = await gitDir.runCommand([
    'for-each-ref',
    '--format=%(refname:short) %(upstream:track)',
    'refs/heads',
  ], throwOnError: false);

  if (result.exitCode != 0) {
    throw GitCleanException('Error listing branches: ${result.stderr}');
  }

  final branchesToDelete = <String>[];
  final lines = LineSplitter.split(result.stdout as String);

  var currentIsGone = false;

  for (final line in lines) {
    // line format: "branchname [gone]" or "branchname "
    // (empty track if no upstream or up-to-date)
    // or "branchname [ahead 1]" etc.
    final parts = line.split(' ');
    if (parts.length >= 2 && parts[1] == '[gone]') {
      final branchName = parts[0];
      if (branchName == 'master' || branchName == 'main') {
        print('Skipping $branchName despite it being marked as [gone].');
        continue;
      }

      if (branchName == currentBranch) {
        currentIsGone = true;
      }

      branchesToDelete.add(branchName);
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
      // (which is in branchesToDelete)
    } else {
      print(
        'Current branch $currentBranch is gone, but no primary branch found '
        'to switch to.',
      );
      print('Skipping deletion of current branch.');
      branchesToDelete.remove(currentBranch);
    }
  } else if (branchesToDelete.contains(currentBranch)) {
    // This case shouldn't be reached if logic is consistent, but safety net:
    branchesToDelete.remove(currentBranch);
  }

  if (branchesToDelete.isEmpty) {
    print('No local branches found with deleted upstreams.');
    return;
  }

  print('Found ${branchesToDelete.length} branches to delete:');
  for (final branch in branchesToDelete) {
    print('  $branch');
  }

  // 4. Delete the branches
  for (final branch in branchesToDelete) {
    print('Deleting $branch...');
    final delResult = await gitDir.runCommand([
      'branch',
      '-D',
      branch,
    ], throwOnError: false);
    if (delResult.exitCode != 0) {
      print('Failed to delete $branch: ${delResult.stderr}');
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
