import 'dart:io';

import 'package:git/git.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_extensions.dart';
import 'package:kevmoo_scripts/src/git_up.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  late String localPath;
  late GitDir localGitDir;

  setUp(() async {
    // 1. Create a "remote" repo
    await d.dir('remote', [d.file('README.md', 'remote readme')]).create();
    final remotePath = p.join(d.sandbox, 'remote');
    final remoteGitDir = await GitDir.init(remotePath, allowContent: true);
    await remoteGitDir.configureTestIdentity();
    await remoteGitDir.runCommand(['branch', '-M', 'main']);
    await remoteGitDir.runCommand(['add', '.']);
    await remoteGitDir.runCommand(['commit', '-m', 'Initial commit']);

    // 2. Clone to "local"
    localPath = p.join(d.sandbox, 'local');
    await Process.run('git', ['clone', remotePath, localPath]);

    localGitDir = await GitDir.fromExisting(localPath);
    await localGitDir.configureTestIdentity();

    // 3. Set origin/HEAD explicitly to be safe
    await localGitDir.runCommand(['remote', 'set-head', 'origin', 'main']);
  });

  test('Success case: finds origin/HEAD and updates', () async {
    // Keep this as a full integration test
    final defaultBranch = await getDefaultBranch(localGitDir);

    await expectLater(
      () async {
        final exitCode = await wrappedForTesting(
          () => gitUp(workingDirectory: localPath),
        );
        expect(exitCode, 0);
      },
      prints(
        allOf(
          contains('Default branch: $defaultBranch'),
          contains('Successfully updated $defaultBranch.'),
        ),
      ),
    );
  });

  test('Success case with git-up.post hook', () async {
    final defaultBranch = await getDefaultBranch(localGitDir);
    await localGitDir.runCommand([
      'config',
      'git-up.post',
      'echo hook_run>hook_out.txt',
    ]);

    await expectLater(
      () async {
        final exitCode = await wrappedForTesting(
          () => gitUp(workingDirectory: localPath),
        );
        expect(exitCode, 0);
      },
      prints(
        allOf(
          contains('Default branch: $defaultBranch'),
          contains('Successfully updated $defaultBranch.'),
          contains('Running post-command: echo hook_run>hook_out.txt'),
        ),
      ),
    );

    final file = File(p.join(localPath, 'hook_out.txt'));
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync().trim(), 'hook_run');
  });

  test('Failure case with failing git-up.post hook', () async {
    final defaultBranch = await getDefaultBranch(localGitDir);
    await localGitDir.runCommand(['config', 'git-up.post', 'exit 42']);

    await expectLater(
      () async {
        await expectLater(
          () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
          throwsA(
            isA<GitUpException>()
                .having((e) => e.exitCode, 'exitCode', 42)
                .having(
                  (e) => e.message,
                  'message',
                  contains('Post-command failed with exit code 42: exit 42'),
                ),
          ),
        );
      },
      prints(
        allOf(
          contains('Default branch: $defaultBranch'),
          contains('Successfully updated $defaultBranch.'),
          contains('Running post-command: exit 42'),
        ),
      ),
    );
  });

  test('getDefaultBranch fails when origin/HEAD is missing', () async {
    // Delete origin/HEAD in the clone
    await localGitDir.runCommand(['remote', 'set-head', 'origin', '-d']);

    await expectLater(() async {
      await expectLater(
        () => wrappedForTesting(() => getDefaultBranch(localGitDir)),
        throwsA(
          isA<GitUpException>().having(
            (e) => e.exitCode,
            'exitCode',
            ExitCode.config.code,
          ),
        ),
      );
    }, prints(contains('Error: origin/HEAD is not set for this repository.')));
  });

  test('verifyAlignment fails when local branch has no upstream', () async {
    final defaultBranch = await getDefaultBranch(localGitDir);

    // Unset the upstream for the default branch in the clone
    await localGitDir.runCommand(['branch', '--unset-upstream', defaultBranch]);

    await expectLater(
      () async {
        await expectLater(
          () => wrappedForTesting(
            () => verifyAlignment(localGitDir, defaultBranch),
          ),
          throwsA(
            isA<GitUpException>().having(
              (e) => e.exitCode,
              'exitCode',
              ExitCode.config.code,
            ),
          ),
        );
      },
      prints(
        contains(
          'Error: Local branch "$defaultBranch" has no upstream configured.',
        ),
      ),
    );
  });

  test(
    'verifyAlignment fails when local branch tracks wrong upstream',
    () async {
      final defaultBranch = await getDefaultBranch(localGitDir);

      // Create a fake remote tracking branch in the clone
      await localGitDir.runCommand([
        'update-ref',
        'refs/remotes/origin/feature',
        'HEAD',
      ]);

      // Set the upstream of the local default branch to something else
      await localGitDir.runCommand([
        'branch',
        '--set-upstream-to=origin/feature',
        defaultBranch,
      ]);

      await expectLater(
        () async {
          await expectLater(
            () => wrappedForTesting(
              () => verifyAlignment(localGitDir, defaultBranch),
            ),
            throwsA(
              isA<GitUpException>().having(
                (e) => e.exitCode,
                'exitCode',
                ExitCode.config.code,
              ),
            ),
          );
        },
        prints(
          contains(' tracks "origin/feature", not "origin/$defaultBranch".'),
        ),
      );
    },
  );

  test('gitUp fails when working tree is dirty and conflicts', () async {
    final filePath = p.join(localPath, 'conflict.txt');
    File(filePath).writeAsStringSync('content A');
    await localGitDir.runCommand(['add', 'conflict.txt']);
    await localGitDir.runCommand(['commit', '-m', 'add conflict.txt']);

    await localGitDir.runCommand(['checkout', '-b', 'feature']);

    File(filePath).writeAsStringSync('content B');
    await localGitDir.runCommand(['add', 'conflict.txt']);
    await localGitDir.runCommand(['commit', '-m', 'update conflict.txt']);

    File(filePath).writeAsStringSync('content C');

    await expectLater(
      () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
      throwsA(isA<GitUpException>()),
    );
  });

  test('gitUp cleans up standard-merged gone branches', () async {
    // 1. Create and push feature-merged
    await localGitDir.runCommand(['checkout', '-b', 'feature-merged']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-merged']);

    // 2. Switch back to main locally
    await localGitDir.runCommand(['checkout', 'main']);

    // 3. Delete remote branch
    final remoteGitDir = await GitDir.fromExisting(p.join(d.sandbox, 'remote'));
    await remoteGitDir.runCommand(['branch', '-D', 'feature-merged']);

    // 4. Run gitUp
    await expectLater(
      () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
      prints(
        allOf(
          contains('Fetching and pruning...'),
          contains('Checking safety of 1 branches with gone upstreams...'),
          contains('Deleting feature-merged...'),
        ),
      ),
    );

    // Verify it was deleted
    final branches = await localGitDir.branches();
    expect(
      branches.map((b) => b.branchName),
      isNot(contains('feature-merged')),
    );
  });

  test('gitUp does NOT delete unmerged gone branches', () async {
    // 1. Create and commit to feature-unmerged
    await localGitDir.runCommand(['checkout', '-b', 'feature-unmerged']);
    final filePath = p.join(localPath, 'unmerged.txt');
    File(filePath).writeAsStringSync('unmerged content');
    await localGitDir.runCommand(['add', 'unmerged.txt']);
    await localGitDir.runCommand(['commit', '-m', 'Unmerged commit']);
    final sha = await localGitDir.getShortSha();

    // 2. Push to remote
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-unmerged']);

    // 3. Switch to main
    await localGitDir.runCommand(['checkout', 'main']);

    // 4. Delete remote branch
    final remoteGitDir = await GitDir.fromExisting(p.join(d.sandbox, 'remote'));
    await remoteGitDir.runCommand(['branch', '-D', 'feature-unmerged']);

    // 5. Run gitUp - should skip deletion and print a warning
    await expectLater(
      () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
      prints(
        allOf(
          contains('Checking safety of 1 branches with gone upstreams...'),
          contains(
            'Warning: Branch "feature-unmerged" ($sha) has a gone upstream '
            'but contains unmerged commits. Skipping deletion.',
          ),
        ),
      ),
    );

    // Verify it was NOT deleted
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), contains('feature-unmerged'));
  });

  test('gitUp cleans up squash-merged gone branches', () async {
    // 1. Create and commit to feature-squash
    await localGitDir.runCommand(['checkout', '-b', 'feature-squash']);
    final filePath = p.join(localPath, 'squash.txt');
    File(filePath).writeAsStringSync('squash content');
    await localGitDir.runCommand(['add', 'squash.txt']);
    await localGitDir.runCommand(['commit', '-m', 'Squash commit']);

    // 2. Push to remote
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-squash']);

    // 3. Switch to main
    await localGitDir.runCommand(['checkout', 'main']);

    // 4. Simulate squash merge on remote
    final remoteGitDir = await GitDir.fromExisting(p.join(d.sandbox, 'remote'));
    final remoteFilePath = p.join(d.sandbox, 'remote', 'squash.txt');
    File(remoteFilePath).writeAsStringSync('squash content');
    await remoteGitDir.runCommand(['add', 'squash.txt']);
    await remoteGitDir.runCommand(['commit', '-m', 'Squashed PR commit (#1)']);

    // 5. Delete remote branch feature-squash
    await remoteGitDir.runCommand(['branch', '-D', 'feature-squash']);

    // 6. Run gitUp - should pull squashed main and clean up feature-squash
    await expectLater(
      () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
      prints(
        allOf(
          contains('Successfully updated main.'),
          contains('Checking safety of 1 branches with gone upstreams...'),
          contains('Deleting feature-squash...'),
        ),
      ),
    );

    // Verify it was deleted
    final branches = await localGitDir.branches();
    expect(
      branches.map((b) => b.branchName),
      isNot(contains('feature-squash')),
    );
  });
}
