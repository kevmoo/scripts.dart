import 'dart:io';

import 'package:git/git.dart';
import 'package:kevmoo_scripts/src/git_clean.dart';
import 'package:kevmoo_scripts/src/util.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  late String remotePath;
  late String localPath;
  late GitDir remoteGitDir;
  late GitDir localGitDir;

  setUp(() async {
    // 1. Create a "remote" repo
    // We use a normal repo and commit to it, to act as a remote.
    await d.dir('remote', [d.file('README.md', 'remote readme')]).create();
    remotePath = p.join(d.sandbox, 'remote');

    // Init remote as a git repo
    // GitDir.init defaults to `git init .`
    // We need to ensure we have a 'main' branch if default is 'master'
    // (depending on git config)
    remoteGitDir = await GitDir.init(remotePath, allowContent: true);

    // Configure user
    await remoteGitDir.runCommand(['config', 'user.email', 'test@test.com']);
    await remoteGitDir.runCommand(['config', 'user.name', 'Tester']);

    // Rename branch to main just in case (if it initialized as master)
    // Or we could have used --initial-branch=main if passed to init, but
    // GitDir.init might not support it args
    // asking simple `git branch -m main` works if we are on master
    // But `GitDir.init` might return us on the default branch.
    // Let's safe-guard by forcing branch name if needed, or better, just ensure
    // we use 'main'
    // Actually, `GitDir.init` usually runs `git init`.
    // Let's assume we can rename it.
    await remoteGitDir.runCommand(['branch', '-M', 'main']);

    await remoteGitDir.runCommand(['add', '.']);
    await remoteGitDir.runCommand(['commit', '-m', 'Initial commit']);

    // 2. Clone to "local"
    localPath = p.join(d.sandbox, 'local');

    await Process.run('git', ['clone', remotePath, localPath]);

    localGitDir = await GitDir.fromExisting(localPath);
    await localGitDir.runCommand(['config', 'user.email', 'test@test.com']);
    await localGitDir.runCommand(['config', 'user.name', 'Tester']);

    // Verify setup
    expect(await localGitDir.isWorkingTreeClean(), isTrue);
  });

  test('cleans up deleted branch', () async {
    // Create branch 'feature' in local
    await localGitDir.runCommand(['checkout', '-b', 'feature']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature']);

    // Switch back to main in local
    await localGitDir.runCommand(['checkout', 'main']);

    // Now delete 'feature' in REMOTE
    await remoteGitDir.runCommand(['branch', '-D', 'feature']);

    // Run git_clean API
    await _runClean(
      localGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: main',
        'Primary branch identified as: main',
        'Attempting to fast-forward main...',
        'main is already up to date.',
        'Found 1 branches to delete:',
        '  feature (',
        ')',
        'Deleting feature...',
        'Deleted feature',
      ]),
    );

    // Verify 'feature' is gone in local
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), isNot(contains('feature')));
  });

  test('switches from deleted branch to main', () async {
    // Create branch 'feature-gone'
    await localGitDir.runCommand(['checkout', '-b', 'feature-gone']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-gone']);

    // Delete 'feature-gone' in REMOTE
    await remoteGitDir.runCommand(['branch', '-D', 'feature-gone']);

    // Ensure we are ON 'feature-gone' locally
    final currentBr = await localGitDir.currentBranch();
    expect(currentBr.branchName, 'feature-gone');

    // Run git_clean API
    await _runClean(
      localGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: feature-gone',
        'Primary branch identified as: main',
        'Current branch feature-gone is gone. Switching to main...',
        'Attempting to fast-forward main...',
        'main is already up to date.',
        'Found 1 branches to delete:',
        '  feature-gone (',
        ')',
        'Deleting feature-gone...',
        'Deleted feature-gone',
      ]),
    );

    // Verify we are now on 'main'
    final newBr = await localGitDir.currentBranch();
    expect(newBr.branchName, 'main');

    // Verify 'feature-gone' is deleted
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), isNot(contains('feature-gone')));
  });

  test('does not delete protected branches (main)', () async {
    await _runClean(
      localGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: main',
        'Primary branch identified as: main',
        'Attempting to fast-forward main...',
        'main is already up to date.',
        'No local branches found with deleted upstreams.',
      ]),
    );
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), contains('main'));
  });

  test('does not delete other branches that are valid', () async {
    await localGitDir.runCommand(['checkout', '-b', 'keep-me']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'keep-me']);
    await localGitDir.runCommand(['checkout', 'main']);

    // keep-me exists on remote, so should NOT be deleted
    await _runClean(
      localGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: main',
        'Primary branch identified as: main',
        'Attempting to fast-forward main...',
        'main is already up to date.',
        'No local branches found with deleted upstreams.',
      ]),
    );

    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), contains('keep-me'));
  });
  test('cleans up deleted branch and prints SHA', () async {
    // Create branch 'feature' in local
    await localGitDir.runCommand(['checkout', '-b', 'feature']);
    await d.file('local/feature_file', 'content').create();
    await localGitDir.runCommand(['add', '.']);
    await localGitDir.runCommand(['commit', '-m', 'Feature commit']);
    final featureSha = (await localGitDir.runCommand([
      'rev-parse',
      'HEAD',
    ])).stdout.toString().trim().substring(0, 7);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature']);

    // Switch back to main in local
    await localGitDir.runCommand(['checkout', 'main']);

    // Now delete 'feature' in REMOTE
    await remoteGitDir.runCommand(['branch', '-D', 'feature']);

    // Verify 'feature' is gone in local AND verify SHA in output
    // Measure output
    await _runClean(
      localGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: main',
        'Primary branch identified as: main',
        'Attempting to fast-forward main...',
        'main is already up to date.',
        'Found 1 branches to delete:',
        '  feature ($featureSha)',
        'Deleting feature...',
        'Deleted feature',
      ]),
    );

    // Verify 'feature' is gone in local
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), isNot(contains('feature')));
  });

  test('switches from deleted branch to main and fast-forwards', () async {
    // Create branch 'feature-gone'
    await localGitDir.runCommand(['checkout', '-b', 'feature-gone']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-gone']);

    // Advance 'main' on remote
    await remoteGitDir.runCommand(['checkout', 'main']);
    await d.file('remote/new_file', 'new content').create();
    await remoteGitDir.runCommand(['add', '.']);
    await remoteGitDir.runCommand(['commit', '-m', 'New commit on main']);
    // No need to push, remoteGitDir IS the remote.

    // Local main is already behind remote main (which has 2 commits now)
    await localGitDir.runCommand(['checkout', 'main']);

    // Switch to feature-gone
    await localGitDir.runCommand(['checkout', 'feature-gone']);

    // Delete 'feature-gone' in REMOTE
    await remoteGitDir.runCommand(['branch', '-D', 'feature-gone']);

    // Capture print output
    await _runClean(
      localGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: feature-gone',
        'Primary branch identified as: main',
        'Current branch feature-gone is gone. Switching to main...',
        'Attempting to fast-forward main...',
        'Fast-forwarded main.',
        'Found 1 branches to delete:',
        '  feature-gone (',
        ')',
        'Deleting feature-gone...',
        'Deleted feature-gone',
      ]),
    );

    // Verify we are now on 'main'
    final newBr = await localGitDir.currentBranch();
    expect(newBr.branchName, 'main');

    // Verify we fast-forwarded
    // origin/main should be ahead of original local main
    // We can check if new_file exists in local
    final newFile = File(p.join(localPath, 'new_file'));
    expect(await newFile.exists(), isTrue);
  });

  test('runs correctly from a subdirectory', () async {
    // Create branch 'feature-sub'
    await localGitDir.runCommand(['checkout', '-b', 'feature-sub']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-sub']);

    // Switch to main
    await localGitDir.runCommand(['checkout', 'main']);

    // Delete 'feature-sub' in REMOTE
    await remoteGitDir.runCommand(['branch', '-D', 'feature-sub']);

    // Create a subdirectory
    final subDir = p.join(localPath, 'subdir');
    await Directory(subDir).create();

    // We can't really "run from subdirectory" easily with the current
    // `clean(GitDir)` API
    // because `clean` takes a `GitDir` which already has the root.
    // The "subdirectory" logic is in `bin/git_clean.dart` which calls `git rev-parse`.
    // Test that `GitDir.fromExisting` works if we pass the root, essentially.
    // But `bin/git_clean.dart` logic is what we want to test.
    // We can simulate the `bin/git_clean.dart` logic:

    final result = await Process.run(
      'git',
      ['rev-parse', '--show-toplevel'],
      workingDirectory: subDir,
      runInShell: true,
    );
    expect(result.exitCode, 0);
    final gitRoot = (result.stdout as String).trim();
    expect(gitRoot, equals(localGitDir.path));

    // If we can get the GitDir from there, `clean` should work.
    final subDirGitDir = await GitDir.fromExisting(gitRoot);
    await _runClean(
      subDirGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: main',
        'Primary branch identified as: main',
        'Attempting to fast-forward main...',
        'main is already up to date.',
        'Found 1 branches to delete:',
        '  feature-sub (',
        ')',
        'Deleting feature-sub...',
        'Deleted feature-sub',
      ]),
    );

    // Verify 'feature-sub' is deleted
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), isNot(contains('feature-sub')));
  });

  test('throws on fetch error', () async {
    // 1. Corrupt remote config to fail fetch
    await localGitDir.runCommand([
      'config',
      'remote.origin.url',
      'https://invalid.example.com/repo.git',
    ]);

    await _runClean(
      localGitDir,
      printsMatcher: contains('Fetching and pruning...'),
      throwsMatcher: isA<GitCleanException>().having(
        (e) => e.message,
        'message',
        contains('Error fetching'),
      ),
    );
  });

  test('throws on dirty checkout error', () async {
    // 1. Checkout main
    // 2. Checkout -b feature-conflict
    // 3. Push
    await localGitDir.runCommand(['checkout', 'main']);
    await localGitDir.runCommand(['checkout', '-b', 'feature-conflict']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-conflict']);

    // 4. Checkout main, add file
    await localGitDir.runCommand(['checkout', 'main']);
    await d.file('local/conflict.txt', 'main content').create();
    await localGitDir.runCommand(['add', '.']);
    await localGitDir.runCommand(['commit', '-m', 'Add conflict.txt']);

    // 5. Delete remote feature-conflict
    await remoteGitDir.runCommand(['branch', '-D', 'feature-conflict']);

    // 6. Checkout feature-conflict (it does not have conflict.txt)
    await localGitDir.runCommand(['checkout', 'feature-conflict']);

    // 7. Create untracked conflict.txt
    await d.file('local/conflict.txt', 'conflict content').create();

    // 8. Run clean -> Should fail switching to main
    await _runClean(
      localGitDir,
      printsMatcher: stringContainsInOrder([
        'Fetching and pruning...',
        'Current branch: feature-conflict',
        'Primary branch identified as: main',
        'Current branch feature-conflict is gone. Switching to main...',
      ]),
      throwsMatcher: isA<GitCleanException>().having(
        (e) => e.message,
        'message',
        contains('Error switching to main'),
      ),
    );
  });
}

Future<void> _runClean(
  GitDir gitDir, {
  required Object printsMatcher,
  Object? exitCode = 0,
  Matcher? throwsMatcher,
}) async {
  int? theExitCode;
  // Run git_clean API
  await expectLater(() async {
    if (throwsMatcher != null) {
      await expectLater(
        () => wrappedForTesting(() => clean(gitDir)),
        throwsA(throwsMatcher),
      );
    } else {
      theExitCode = await wrappedForTesting(() => clean(gitDir));
    }
  }, prints(printsMatcher));

  if (throwsMatcher == null) {
    expect(theExitCode, exitCode);
  }
}
