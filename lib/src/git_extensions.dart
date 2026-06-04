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

  /// Configures a standard test identity for the repository.
  ///
  /// This is useful in tests to prevent dirty working trees on Windows/CI.
  Future<void> configureTestIdentity() async {
    await runCommand(['config', 'user.email', 'test@test.com']);
    await runCommand(['config', 'user.name', 'Tester']);
    await runCommand(['config', 'core.autocrlf', 'false']);
  }
}
