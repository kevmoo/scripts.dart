import 'dart:convert';
import 'dart:io';
import 'package:git/git.dart';

/// Extensions on [GitDir] to provide high-level operations used in this
/// package.
///
/// These are candidates for moving to `package:git`.
extension GitDirExtensions on GitDir {
  /// Resolves the Git repository root directory from the [workingDirectory] or
  /// its parents.
  ///
  /// Throws a [ProcessException] if it's not a Git repository.
  static Future<GitDir> fromCurrentDirectory([String? workingDirectory]) async {
    workingDirectory ??= Directory.current.path;
    final result = await Process.run('git', [
      'rev-parse',
      '--show-toplevel',
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        ['rev-parse', '--show-toplevel'],
        result.stderr as String,
        result.exitCode,
      );
    }
    final gitRoot = (result.stdout as String).trim();
    return GitDir.fromExisting(gitRoot);
  }

  /// Gets the short SHA of a given ref (defaults to 'HEAD').
  Future<String> getShortSha([String ref = 'HEAD']) async {
    final result = await runCommand(['rev-parse', '--short', ref]);
    return (result.stdout as String).trim();
  }

  /// Checks if a local branch exists.
  Future<bool> hasBranch(String branchName) async {
    final result = await runCommand([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/$branchName',
    ], throwOnError: false);
    return result.exitCode == 0;
  }

  /// Gets the upstream of a branch.
  ///
  /// Returns null if no upstream is configured.
  Future<String?> getUpstream(String branchName) async {
    final result = await runCommand([
      'rev-parse',
      '--abbrev-ref',
      '$branchName@{u}',
    ], throwOnError: false);

    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  }

  /// Determines the default branch by checking origin/HEAD or sniffing for main/master.
  Future<String?> getDefaultBranch() async {
    final revParseResult = await runCommand([
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

    // Sniff for main or master
    for (final branch in ['main', 'master']) {
      final result = await runCommand([
        'show-ref',
        '--verify',
        '--quiet',
        'refs/remotes/origin/$branch',
      ], throwOnError: false);
      if (result.exitCode == 0) {
        return branch;
      }
    }
    return null;
  }

  /// Fetches from remote, optionally pruning remote-tracking branches that no
  /// longer exist.
  Future<void> fetch({bool prune = false}) async {
    final args = ['fetch'];
    if (prune) args.add('--prune');
    final result = await runCommand(args, throwOnError: false);
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        args,
        result.stderr as String,
        result.exitCode,
      );
    }
  }

  /// Attempts to fast-forward merge the current branch with its upstream.
  Future<ProcessResult> fastForwardMerge([String ref = '@{u}']) =>
      runCommand(['merge', '--ff-only', ref], throwOnError: false);

  /// Deletes a local branch.
  Future<void> deleteBranch(String branchName, {bool force = false}) async {
    final args = ['branch', force ? '-D' : '-d', branchName];
    final result = await runCommand(args, throwOnError: false);
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        args,
        result.stderr as String,
        result.exitCode,
      );
    }
  }

  /// Gets all local branches along with their upstream tracking status.
  ///
  /// Returns a map where the key is the branch name and the value is a record
  /// containing the SHA and whether the upstream is 'gone'.
  Future<Map<String, ({String sha, bool isUpstreamGone})>>
  getBranchesStatus() async {
    final result = await runCommand([
      'for-each-ref',
      '--format=%(refname:short) %(upstream:track) %(objectname:short)',
      'refs/heads',
    ]);

    final status = <String, ({String sha, bool isUpstreamGone})>{};
    final lines = LineSplitter.split(result.stdout as String);

    for (final line in lines) {
      final firstSpace = line.indexOf(' ');
      final lastSpace = line.lastIndexOf(' ');

      if (firstSpace != -1 && lastSpace > firstSpace) {
        final branchName = line.substring(0, firstSpace);
        final track = line.substring(firstSpace + 1, lastSpace).trim();
        final sha = line.substring(lastSpace + 1);

        status[branchName] = (sha: sha, isUpstreamGone: track == '[gone]');
      }
    }
    return status;
  }

  /// Checks if [branchName] is merged into [targetBranch].
  ///
  /// A branch is merged if:
  /// 1. It is an ancestor of [targetBranch] (i.e. standard merge or rebase).
  /// 2. Or, a three-way merge of [branchName] into [targetBranch] results in a
  ///    tree identical to [targetBranch] (i.e. squash merge).
  Future<bool> isMergedInto(String branchName, String targetBranch) async {
    // 1. Fast ancestor check
    final ancestorResult = await runCommand([
      'merge-base',
      '--is-ancestor',
      branchName,
      targetBranch,
    ], throwOnError: false);
    if (ancestorResult.exitCode == 0) {
      return true;
    }

    // 2. Squash merge check using git merge-tree
    try {
      final targetTreeResult = await runCommand([
        'rev-parse',
        '$targetBranch^{tree}',
      ]);
      final targetTree = (targetTreeResult.stdout as String).trim();

      final mergeTreeResult = await runCommand([
        'merge-tree',
        targetBranch,
        branchName,
      ], throwOnError: false);

      if (mergeTreeResult.exitCode == 0) {
        final mergeTree = (mergeTreeResult.stdout as String)
            .split('\n')
            .first
            .trim();
        return mergeTree == targetTree;
      }
    } catch (_) {
      // Fallback to false for safety
    }
    return false;
  }

  /// Checks if the `gh` CLI is available and authenticated.
  Future<bool> isGitHubCliAvailable() async {
    try {
      final result = await Process.run('gh', ['auth', 'status']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Gets the PR number stored in the local git config for [branchName], if
  /// any.
  Future<int?> getLocalPrNumber(String branchName) async {
    final result = await runCommand([
      'config',
      '--get',
      'branch.$branchName.gh-pr-number',
    ], throwOnError: false);

    if (result.exitCode != 0) return null;
    final output = (result.stdout as String).trim();
    return int.tryParse(output);
  }

  /// Queries the GitHub API for the state of a PR by its number.
  ///
  /// Returns the PR state (e.g. 'MERGED', 'CLOSED', 'OPEN') or null if not
  /// found.
  Future<String?> getPrStateByNumber(int prNumber) async {
    try {
      final result = await Process.run('gh', [
        'pr',
        'view',
        prNumber.toString(),
        '--json',
        'state',
      ]);
      if (result.exitCode == 0) {
        final data =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        return data['state'] as String?;
      }
    } catch (_) {
      // Ignore and return null
    }
    return null;
  }

  /// Queries the GitHub API for the state of a PR by branch name.
  ///
  /// Returns the PR state (e.g. 'MERGED', 'CLOSED', 'OPEN') or null if not
  /// found.
  Future<String?> getPrStateByBranch(String branchName) async {
    try {
      final result = await Process.run('gh', [
        'pr',
        'view',
        branchName,
        '--json',
        'state',
      ]);
      if (result.exitCode == 0) {
        final data =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        return data['state'] as String?;
      }
    } catch (_) {
      // Ignore and return null
    }
    return null;
  }

  /// Retrieves the state of recent PRs in the repository.
  ///
  /// Returns a map of head branch names to their PR state.
  Future<Map<String, String>> getRecentPrsState({int limit = 100}) async {
    final prStates = <String, String>{};
    try {
      final result = await Process.run('gh', [
        'pr',
        'list',
        '--state',
        'all',
        '--limit',
        limit.toString(),
        '--json',
        'headRefName,state',
      ]);
      if (result.exitCode == 0) {
        final list = jsonDecode(result.stdout as String) as List<dynamic>;
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            final head = item['headRefName'] as String?;
            final state = item['state'] as String?;
            if (head != null && state != null) {
              prStates[head] = state;
            }
          }
        }
      }
    } catch (_) {
      // Ignore and return empty map
    }
    return prStates;
  }

  /// Configures a standard test identity for the repository.
  ///
  /// This is useful in tests to prevent dirty working trees on Windows/CI.
  Future<void> configureTestIdentity() async {
    await runCommand(['config', 'user.email', 'test@test.com']);
    await runCommand(['config', 'user.name', 'Tester']);
    await runCommand(['config', 'core.autocrlf', 'false']);
  }
}
