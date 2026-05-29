import 'dart:io';
import 'package:git/git.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_gm.dart';
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
          () => gitGm(workingDirectory: localPath),
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

  test('Success case with git-gm.post hook', () async {
    final defaultBranch = await getDefaultBranch(localGitDir);
    await localGitDir.runCommand([
      'config',
      'git-gm.post',
      'echo "hook run" > hook_out.txt',
    ]);

    await expectLater(
      () async {
        final exitCode = await wrappedForTesting(
          () => gitGm(workingDirectory: localPath),
        );
        expect(exitCode, 0);
      },
      prints(
        allOf(
          contains('Default branch: $defaultBranch'),
          contains('Successfully updated $defaultBranch.'),
          contains('Running post-command: echo "hook run" > hook_out.txt'),
        ),
      ),
    );

    final file = File(p.join(localPath, 'hook_out.txt'));
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync().trim(), 'hook run');
  });

  test('Failure case with failing git-gm.post hook', () async {
    final defaultBranch = await getDefaultBranch(localGitDir);
    await localGitDir.runCommand(['config', 'git-gm.post', 'exit 42']);

    await expectLater(
      () async {
        await expectLater(
          () => wrappedForTesting(() => gitGm(workingDirectory: localPath)),
          throwsA(
            isA<GitGmException>()
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
          isA<GitGmException>().having(
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
            isA<GitGmException>().having(
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
              isA<GitGmException>().having(
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

  test('gitGm fails when working tree is dirty and conflicts', () async {
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
      () => wrappedForTesting(() => gitGm(workingDirectory: localPath)),
      throwsA(isA<GitGmException>()),
    );
  });
}

extension on GitDir {
  Future<void> configureTestIdentity() async {
    await runCommand(['config', 'user.email', 'test@test.com']);
    await runCommand(['config', 'user.name', 'Tester']);
    await runCommand(['config', 'core.autocrlf', 'false']);
  }
}
