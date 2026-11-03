import 'dart:io';

import 'package:git/git.dart';

import '../process_utils.dart';

/// Environment variables that prevent `git` from blocking on credential or
/// SSH terminal prompts in automated CLI runs.
const _gitNonInteractiveEnv = <String, String>{'GIT_TERMINAL_PROMPT': '0'};

/// Environment variables for read-only `git` queries (`status`, `rev-parse`,
/// `for-each-ref`, `worktree list`), skipping optional `.git/index.lock`
/// writes alongside terminal prompt suppression.
const _gitReadOnlyEnv = <String, String>{
  'GIT_TERMINAL_PROMPT': '0',
  'GIT_OPTIONAL_LOCKS': '0',
};

/// Default synchronous `git` runner with [_gitNonInteractiveEnv].
ProcessResult _defaultGitSyncRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.runSync(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: _gitNonInteractiveEnv,
);

/// Read-only synchronous `git` runner with [_gitReadOnlyEnv].
ProcessResult _readOnlyGitSyncRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.runSync(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: _gitReadOnlyEnv,
);

/// Default asynchronous `git` runner with [_gitNonInteractiveEnv].
Future<ProcessResult> _defaultGitAsyncRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.run(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: _gitNonInteractiveEnv,
);

/// Read-only asynchronous `git` runner with [_gitReadOnlyEnv].
Future<ProcessResult> _readOnlyGitAsyncRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.run(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: _gitReadOnlyEnv,
);

/// Normalizes stdout from `git rev-parse --abbrev-ref origin/HEAD` by stripping
/// a leading `origin/` prefix.
///
/// Returns `null` when [rawStdout] is empty or unresolved (`HEAD` /
/// `origin/HEAD`).
String? parseOriginHeadBranchOutput(String rawStdout) {
  final output = rawStdout.trim();
  if (output.isEmpty || output == 'HEAD' || output == 'origin/HEAD') {
    return null;
  }
  if (output.startsWith('origin/')) {
    final branch = output.substring('origin/'.length);
    return branch.isEmpty ? null : branch;
  }
  return output;
}

/// Shared default [GitCli] instance using non-interactive `git` runners.
const defaultGitCli = GitCli();

/// Thin, mockable `git` CLI helper shared across synchronous and asynchronous
/// `kscripts` commands.
final class GitCli {
  final SyncProcessRunner syncRunner;
  final ProcessRunner asyncRunner;

  const new({
    this.syncRunner = _defaultGitSyncRunner,
    this.asyncRunner = _defaultGitAsyncRunner,
  });

  bool get _usesDefaultSyncRunner =>
      syncRunner == _defaultGitSyncRunner ||
      syncRunner == defaultSyncProcessRunner;

  bool get _usesDefaultAsyncRunner =>
      asyncRunner == _defaultGitAsyncRunner ||
      asyncRunner == defaultProcessRunner;

  /// Runs `git` synchronously with [args].
  ///
  /// When [readOnly] is `true` and no custom test [syncRunner] was injected,
  /// passes `GIT_OPTIONAL_LOCKS=0` in addition to `GIT_TERMINAL_PROMPT=0`.
  ProcessResult runSync(
    List<String> args, {
    String? workingDirectory,
    bool readOnly = false,
  }) {
    final runner = readOnly && _usesDefaultSyncRunner
        ? _readOnlyGitSyncRunner
        : syncRunner;
    return runner('git', args, workingDirectory: workingDirectory);
  }

  /// Runs `git` asynchronously with [args].
  ///
  /// When [readOnly] is `true` and no custom test [asyncRunner] was injected,
  /// passes `GIT_OPTIONAL_LOCKS=0` in addition to `GIT_TERMINAL_PROMPT=0`.
  Future<ProcessResult> run(
    List<String> args, {
    String? workingDirectory,
    bool readOnly = false,
  }) {
    final runner = readOnly && _usesDefaultAsyncRunner
        ? _readOnlyGitAsyncRunner
        : asyncRunner;
    return runner('git', args, workingDirectory: workingDirectory);
  }

  /// Runs `git` synchronously and returns trimmed stdout when exit code is `0`
  /// and stdout is non-empty, or `null` on non-zero exit / [ProcessException].
  String? stdoutOrNullSync(
    List<String> args, {
    String? workingDirectory,
    bool readOnly = true,
  }) {
    try {
      final result = runSync(
        args,
        workingDirectory: workingDirectory,
        readOnly: readOnly,
      );
      if (result.exitCode != 0) return null;
      final out = result.stdout.toString().trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// Runs `git` asynchronously and returns trimmed stdout when exit code is `0`
  /// and stdout is non-empty, or `null` on non-zero exit / [ProcessException].
  Future<String?> stdoutOrNull(
    List<String> args, {
    String? workingDirectory,
    bool readOnly = true,
  }) async {
    try {
      final result = await run(
        args,
        workingDirectory: workingDirectory,
        readOnly: readOnly,
      );
      if (result.exitCode != 0) return null;
      final out = result.stdout.toString().trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// Returns `true` when `git` exits with code `0` synchronously.
  bool checkSync(
    List<String> args, {
    String? workingDirectory,
    bool readOnly = true,
  }) {
    try {
      final result = runSync(
        args,
        workingDirectory: workingDirectory,
        readOnly: readOnly,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Returns `true` when `git` exits with code `0` asynchronously.
  Future<bool> check(
    List<String> args, {
    String? workingDirectory,
    bool readOnly = true,
  }) async {
    try {
      final result = await run(
        args,
        workingDirectory: workingDirectory,
        readOnly: readOnly,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Returns the currently checked-out short branch name in [repoPath], or
  /// `null` when detached (`HEAD`) or outside a Git repository.
  String? currentBranchSync(String repoPath) => stdoutOrNullSync(const [
    'branch',
    '--show-current',
  ], workingDirectory: repoPath);

  /// Asynchronously returns the currently checked-out short branch name in
  /// [repoPath], or `null` when detached (`HEAD`) or outside a Git repository.
  Future<String?> currentBranch(String repoPath) => stdoutOrNull(const [
    'branch',
    '--show-current',
  ], workingDirectory: repoPath);

  /// Reads a single `git config --get <key>` value in [workingDirectory].
  String? configGetSync(String key, {required String workingDirectory}) =>
      stdoutOrNullSync([
        'config',
        '--get',
        key,
      ], workingDirectory: workingDirectory);

  /// Synchronously resolves the default branch of [repoPath] from `origin/HEAD`
  /// or by checking `refs/remotes/origin/{main,master}`, falling back to
  /// [fallback].
  String defaultBranchSync(String repoPath, {String fallback = 'main'}) {
    final originHead = stdoutOrNullSync(const [
      'rev-parse',
      '--abbrev-ref',
      'origin/HEAD',
    ], workingDirectory: repoPath);
    if (originHead != null) {
      final parsed = parseOriginHeadBranchOutput(originHead);
      if (parsed != null) return parsed;
    }

    for (final branch in const ['main', 'master']) {
      final exists = checkSync([
        'show-ref',
        '--verify',
        '--quiet',
        'refs/remotes/origin/$branch',
      ], workingDirectory: repoPath);
      if (exists) return branch;
    }

    return fallback;
  }

  /// Synchronously checks whether [dirPath] has uncommitted modifications.
  bool isDirtySync(
    String dirPath, {
    bool includeUntracked = false,
    bool failClosedOnProcessError = false,
  }) {
    final args = ['status', '--porcelain', if (!includeUntracked) '-uno'];
    try {
      final res = runSync(args, workingDirectory: dirPath, readOnly: true);
      if (res.exitCode != 0) return failClosedOnProcessError;
      return res.stdout.toString().trim().isNotEmpty;
    } catch (_) {
      return failClosedOnProcessError;
    }
  }

  /// Asynchronously checks whether [dirPath] has uncommitted modifications.
  Future<bool> isDirty(
    String dirPath, {
    bool includeUntracked = false,
    bool failClosedOnProcessError = false,
  }) async {
    final args = ['status', '--porcelain', if (!includeUntracked) '-uno'];
    try {
      final res = await run(args, workingDirectory: dirPath, readOnly: true);
      if (res.exitCode != 0) return failClosedOnProcessError;
      return res.stdout.toString().trim().isNotEmpty;
    } catch (_) {
      return failClosedOnProcessError;
    }
  }

  /// Synchronously lists worktrees registered in [repoPath].
  List<WorktreeEntry> listWorktreesSync(String repoPath) {
    final res = runSync(
      const ['worktree', 'list', '--porcelain'],
      workingDirectory: repoPath,
      readOnly: true,
    );
    if (res.exitCode != 0) return const [];
    return WorktreeEntry.fromPorcelain(res.stdout.toString());
  }
}
