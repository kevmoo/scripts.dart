import 'dart:convert';
import 'dart:io';
import 'package:git/git.dart';

bool mockGhAvailableForTesting = false;
bool mockGhUnavailableForTesting = false;
Map<String, ({String state, String url, int number, String baseBranch})>?
mockRecentPrsForTesting;

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
  Future<void> fetch({bool prune = false, bool all = false}) async {
    final args = ['fetch'];
    if (all) args.add('--all');
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
  /// containing the SHA, upstream branch name (if any), and whether the
  /// upstream is 'gone'.
  Future<Map<String, ({String sha, String upstream, bool isUpstreamGone})>>
  getBranchesStatus() async {
    const format =
        '--format=%(refname:short)\t%(upstream)\t'
        '%(upstream:track)\t%(objectname:short)';
    final result = await runCommand(['for-each-ref', format, 'refs/heads']);

    final status =
        <String, ({String sha, String upstream, bool isUpstreamGone})>{};
    final lines = LineSplitter.split(result.stdout as String);

    for (final line in lines) {
      final parts = line.split('\t');
      if (parts.length == 4) {
        final branchName = parts[0];
        final upstream = parts[1];
        final track = parts[2];
        final sha = parts[3];

        status[branchName] = (
          sha: sha,
          upstream: upstream,
          isUpstreamGone: track == '[gone]',
        );
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

    // 2. Tree history match check (fast squash-merge check when no other
    //    changes)
    try {
      final branchTreeResult = await runCommand([
        'rev-parse',
        '$branchName^{tree}',
      ], throwOnError: false);
      if (branchTreeResult.exitCode == 0) {
        final branchTree = (branchTreeResult.stdout as String).trim();

        // Get tree hashes of the last 1000 commits in targetBranch's history.
        final targetTreesResult = await runCommand([
          'log',
          targetBranch,
          '--format=%T',
          '-n',
          '1000',
        ], throwOnError: false);

        if (targetTreesResult.exitCode == 0) {
          final targetTrees = (targetTreesResult.stdout as String).split('\n');
          if (targetTrees.contains(branchTree)) {
            return true;
          }
        }
      }
    } catch (_) {
      // Fallback to next check
    }

    // 3. Trial merge check (using git merge-tree)
    // Merges branchName into targetBranch in-memory.
    // If the merge is clean (exit code 0) and the resulting tree is identical
    // to targetBranch's tree, then branchName introduces no new changes.
    try {
      final targetTreeResult = await runCommand([
        'rev-parse',
        '$targetBranch^{tree}',
      ], throwOnError: false);
      if (targetTreeResult.exitCode == 0) {
        final targetTree = (targetTreeResult.stdout as String).trim();

        final mergeTreeResult = await runCommand([
          'merge-tree',
          '--write-tree',
          targetBranch,
          branchName,
        ], throwOnError: false);

        if (mergeTreeResult.exitCode == 0) {
          final mergeTree = (mergeTreeResult.stdout as String).trim();
          if (mergeTree == targetTree) {
            return true;
          }
        }
      }
    } catch (_) {
      // Fallback to returning false
    }

    return false;
  }

  /// Checks if the `gh` CLI is available and authenticated.
  Future<bool> isGitHubCliAvailable() async {
    if (mockGhAvailableForTesting) {
      return true;
    }
    if (mockGhUnavailableForTesting) {
      return false;
    }
    try {
      final result = await Process.run('gh', ['auth', 'status']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Checks if a remote-tracking branch named [branchName] exists for `origin`.
  Future<bool> hasRemoteBranch(String branchName) async {
    final result = await runCommand([
      'show-ref',
      '--verify',
      'refs/remotes/origin/$branchName',
    ], throwOnError: false);
    return result.exitCode == 0;
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

  /// Queries the GitHub API for the PR info by its number.
  ///
  /// Returns the PR state and base branch, or null if not found.
  Future<({String state, String baseBranch})?> getPrInfoByNumber(
    int prNumber,
  ) async {
    try {
      final result = await Process.run('gh', [
        'pr',
        'view',
        prNumber.toString(),
        '--json',
        'state,baseRefName',
      ]);
      if (result.exitCode == 0) {
        final data =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        return (
          state: data['state'] as String? ?? '',
          baseBranch: data['baseRefName'] as String? ?? '',
        );
      }
    } catch (_) {
      // Ignore and return null
    }
    return null;
  }

  /// Queries the GitHub API for the PR info by branch name.
  ///
  /// Returns the PR state and base branch, or null if not found.
  Future<({String state, String baseBranch})?> getPrInfoByBranch(
    String branchName,
  ) async {
    try {
      final result = await Process.run('gh', [
        'pr',
        'view',
        branchName,
        '--json',
        'state,baseRefName',
      ]);
      if (result.exitCode == 0) {
        final data =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        return (
          state: data['state'] as String? ?? '',
          baseBranch: data['baseRefName'] as String? ?? '',
        );
      }
    } catch (_) {
      // Ignore and return null
    }
    return null;
  }

  /// Retrieves the details of recent PRs in the repository.
  ///
  /// Returns a map of head branch names to their PR details.
  Future<
    Map<String, ({String state, String url, int number, String baseBranch})>
  >
  getRecentPrsInfo({int limit = 100}) async {
    if (mockRecentPrsForTesting != null) {
      return mockRecentPrsForTesting!;
    }
    final prs =
        <String, ({String state, String url, int number, String baseBranch})>{};
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
        'headRefName,state,url,number,baseRefName',
      ]);
      if (result.exitCode == 0) {
        final list = jsonDecode(result.stdout as String) as List<dynamic>;
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            final head = item['headRefName'] as String?;
            final state = item['state'] as String?;
            final url = item['url'] as String?;
            final number = item['number'] as int?;
            final baseBranch = item['baseRefName'] as String?;
            if (head != null &&
                state != null &&
                url != null &&
                number != null &&
                baseBranch != null) {
              prs[head] = (
                state: state,
                url: url,
                number: number,
                baseBranch: baseBranch,
              );
            }
          }
        }
      }
    } catch (_) {
      // Ignore and return empty map
    }
    return prs;
  }

  /// Checks if the working tree is dirty (has modified or staged tracked
  /// files).
  ///
  /// Ignores untracked files.
  Future<bool> isDirty() async {
    final result = await runCommand(['status', '--porcelain', '-uno']);
    return (result.stdout as String).trim().isNotEmpty;
  }

  /// Configures a standard test identity for the repository.
  ///
  /// This is useful in tests to prevent dirty working trees on Windows/CI.
  Future<void> configureTestIdentity() async {
    await runCommand(['config', 'user.email', 'test@test.com']);
    await runCommand(['config', 'user.name', 'Tester']);
    await runCommand(['config', 'core.autocrlf', 'false']);
  }

  /// Resolves the given [branchName] to its local ref and/or its upstream ref if
  /// they exist.
  ///
  /// Returns a list of resolved full ref names (e.g.
  /// ['refs/remotes/origin/main', 'refs/heads/main']).
  Future<Set<String>> resolveLookups(String branchName) async {
    if (branchName.isEmpty) return const <String>{};
    final refs = <String>{};

    // Try upstream first (e.g. branchName@{u})
    final upstreamResult = await runCommand([
      'rev-parse',
      '--symbolic-full-name',
      '$branchName@{u}',
    ], throwOnError: false);
    if (upstreamResult.exitCode == 0) {
      refs.add((upstreamResult.stdout as String).trim());
    }

    // Try local branch
    final localResult = await runCommand([
      'rev-parse',
      '--symbolic-full-name',
      branchName,
    ], throwOnError: false);
    if (localResult.exitCode == 0) {
      refs.add((localResult.stdout as String).trim());
    }

    // Try all remote-tracking branches matching the name across all remotes
    final remotesResult = await runCommand([
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
}
