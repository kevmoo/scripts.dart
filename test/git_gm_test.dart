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
  late String scriptsRepoPath;

  setUp(() async {
    scriptsRepoPath = Directory.current.path;

    // Create a sandbox directory for the local clone
    localPath = p.join(d.sandbox, 'local');

    // Clone the scripts repo into the sandbox
    final result = await Process.run('git', [
      'clone',
      scriptsRepoPath,
      localPath,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'Failed to clone repo: ${result.stderr}',
    );

    localGitDir = await GitDir.fromExisting(localPath);
    await localGitDir.configureTestIdentity();
  });

  test('Success case: finds origin/HEAD and updates', () async {
    // Keep this as a full integration test
    final defaultBranch = await getDefaultBranch(localGitDir);

    await expectLater(() async {
      final exitCode = await wrappedForTesting(
        () => gitGm(workingDirectory: localPath),
      );
      expect(exitCode, 0);
    }, prints(contains('Successfully updated $defaultBranch.')));
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
      throwsA(isA<ProcessException>()),
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
