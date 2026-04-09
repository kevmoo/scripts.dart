import 'dart:io';
import 'package:git/git.dart';
import 'package:io/io.dart';
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
/// Throws a [GitGmException] if any step fails with a clear message and
/// exit code.
///
/// [workingDirectory] specifies the directory to start searching for the
/// Git root. Defaults to [Directory.current]`.path`.
Future<void> gitGm({String? workingDirectory}) async {
  workingDirectory ??= Directory.current.path;

  final gitDir = await getGitDir(workingDirectory);

  // 1. Determine Default Branch
  final defaultBranch = await getDefaultBranch(gitDir);

  print('Default branch: $defaultBranch');

  // 2. Verify Alignment
  await verifyAlignment(gitDir, defaultBranch);

  // 3. Checkout default branch
  print('Checking out $defaultBranch...');
  await gitDir.runCommand(['checkout', defaultBranch]);

  // 4. Update with pull --ff-only
  print('Pulling updates...');
  await gitDir.runCommand(['pull', '--ff-only']);

  print('Successfully updated $defaultBranch.');
}

/// Resolves the Git repository root directory.
///
/// Runs `git rev-parse --show-toplevel` from [workingDirectory].
///
/// Returns a [GitDir] instance for the repository.
///
/// Throws a [GitGmException] if the command fails or if it's not a Git
/// repository.
Future<GitDir> getGitDir(String workingDirectory) async {
  ProcessResult result;
  try {
    result = await Process.run('git', [
      'rev-parse',
      '--show-toplevel',
    ], workingDirectory: workingDirectory);
  } on ProcessException catch (e) {
    throw GitGmException(
      'Failed to run git. Is it installed and in your PATH? '
      'Error: ${e.message}',
      exitCode: ExitCode.software.code,
    );
  }

  if (result.exitCode != 0) {
    throw GitGmException(
      result.stderr.toString().trim(),
      exitCode: result.exitCode,
    );
  }

  final gitRoot = (result.stdout as String).trim();
  return GitDir.fromExisting(gitRoot);
}

/// Determines the default branch of the repository.
///
/// First tries to read `origin/HEAD`. If that fails, it sniffs for
/// `refs/remotes/origin/main` and `refs/remotes/origin/master`.
///
/// Returns the name of the default branch (e.g., 'main').
///
/// Throws a [GitGmException] if the default branch cannot be determined.
///
/// [gitDir] is the Git repository to query.
Future<String> getDefaultBranch(GitDir gitDir) async {
  final revParseResult = await gitDir.runCommand([
    'rev-parse',
    '--abbrev-ref',
    'origin/HEAD',
  ], throwOnError: false);

  if (revParseResult.exitCode == 0) {
    final output = (revParseResult.stdout as String).trim();
    if (output.startsWith('origin/')) {
      return output.substring('origin/'.length);
    } else {
      return output;
    }
  } else {
    // Failed to get origin/HEAD. Sniff for main or master.
    String? sniffedBranch;
    for (final branch in ['main', 'master']) {
      final result = await gitDir.runCommand([
        'show-ref',
        '--verify',
        '--quiet',
        'refs/remotes/origin/$branch',
      ], throwOnError: false);
      if (result.exitCode == 0) {
        sniffedBranch = branch;
        break;
      }
    }

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

    throw GitGmException(
      'Cannot determine default branch.',
      exitCode: ExitCode.config.code,
    );
  }
}

/// Verifies that the local branch is aligned with the remote default branch.
///
/// Checks:
/// 1. The local branch with name [defaultBranch] exists.
/// 2. The local branch has an upstream configured.
/// 3. The upstream is `origin/[defaultBranch]`.
///
/// Throws a [GitGmException] with specific advice if any check fails.
///
/// [gitDir] is the Git repository.
/// [defaultBranch] is the name of the default branch to verify.
Future<void> verifyAlignment(GitDir gitDir, String defaultBranch) async {
  final branchExistsResult = await gitDir.runCommand([
    'show-ref',
    '--verify',
    '--quiet',
    'refs/heads/$defaultBranch',
  ], throwOnError: false);

  if (branchExistsResult.exitCode != 0) {
    printError('Warning: Local branch "$defaultBranch" does not exist.');
    throw GitGmException(
      'Local branch does not exist.',
      exitCode: ExitCode.config.code,
    );
  }

  final upstreamResult = await gitDir.runCommand([
    'rev-parse',
    '--abbrev-ref',
    '$defaultBranch@{u}',
  ], throwOnError: false);

  if (upstreamResult.exitCode != 0) {
    printError(
      'Error: Local branch "$defaultBranch" has no upstream configured.',
    );
    _printUpstreamFixSuggestion(defaultBranch);
    throw GitGmException(
      'Branch has no upstream.',
      exitCode: ExitCode.config.code,
    );
  }

  final upstream = (upstreamResult.stdout as String).trim();
  if (upstream != 'origin/$defaultBranch') {
    printError(
      'Error: Local branch "$defaultBranch" tracks "$upstream", not "origin/$defaultBranch".',
    );
    _printUpstreamFixSuggestion(defaultBranch);
    throw GitGmException(
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

/// Exception thrown by `git-gm` operations.
///
/// Contains a user-friendly [message] and an suggested [exitCode].
class GitGmException implements Exception {
  final String message;
  final int exitCode;

  GitGmException(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}
