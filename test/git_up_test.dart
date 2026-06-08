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

  test('gitUp fails immediately when working tree is dirty', () async {
    final filePath = p.join(localPath, 'dirty.txt');
    File(filePath).writeAsStringSync('content A');
    await localGitDir.runCommand(['add', 'dirty.txt']);
    await localGitDir.runCommand(['commit', '-m', 'add dirty.txt']);

    // Make it dirty
    File(filePath).writeAsStringSync('content B');

    await expectLater(() async {
      await expectLater(
        () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
        throwsA(
          isA<GitUpException>().having(
            (e) => e.message,
            'message',
            contains('Working tree is dirty.'),
          ),
        ),
      );
    }, prints(contains('Please commit or stash your changes and try again.')));
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
            'but contains unmerged commits (relative to main). '
            'Skipping deletion.',
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

  test(
    'gitUp cleans up squash-merged gone branches even when main has progressed',
    () async {
      // 1. Create and commit to feature-squash-progressed
      await localGitDir.runCommand([
        'checkout',
        '-b',
        'feature-squash-progressed',
      ]);
      final filePath = p.join(localPath, 'squash_prog.txt');
      File(filePath).writeAsStringSync('squash progressed content');
      await localGitDir.runCommand(['add', 'squash_prog.txt']);
      await localGitDir.runCommand([
        'commit',
        '-m',
        'Squash progressed commit',
      ]);

      // 2. Push to remote
      await localGitDir.runCommand([
        'push',
        '-u',
        'origin',
        'feature-squash-progressed',
      ]);

      // 3. Switch to main
      await localGitDir.runCommand(['checkout', 'main']);

      // 4. Simulate an unrelated commit on remote main
      final remoteGitDir = await GitDir.fromExisting(
        p.join(d.sandbox, 'remote'),
      );
      final remoteUnrelatedPath = p.join(d.sandbox, 'remote', 'unrelated.txt');
      File(remoteUnrelatedPath).writeAsStringSync('unrelated content');
      await remoteGitDir.runCommand(['add', 'unrelated.txt']);
      await remoteGitDir.runCommand([
        'commit',
        '-m',
        'Unrelated commit on main',
      ]);

      // 5. Simulate squash merge on remote main
      final remoteFilePath = p.join(d.sandbox, 'remote', 'squash_prog.txt');
      File(remoteFilePath).writeAsStringSync('squash progressed content');
      await remoteGitDir.runCommand(['add', 'squash_prog.txt']);
      await remoteGitDir.runCommand([
        'commit',
        '-m',
        'Squashed PR progressed commit (#2)',
      ]);

      // 6. Delete remote branch feature-squash-progressed
      await remoteGitDir.runCommand([
        'branch',
        '-D',
        'feature-squash-progressed',
      ]);

      // 7. Run gitUp - should pull squashed main (with both commits) and
      //    clean up feature-squash-progressed
      await expectLater(
        () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
        prints(
          allOf(
            contains('Successfully updated main.'),
            contains('Checking safety of 1 branches with gone upstreams...'),
            contains('Deleting feature-squash-progressed...'),
          ),
        ),
      );

      // Verify it was deleted
      final branches = await localGitDir.branches();
      expect(
        branches.map((b) => b.branchName),
        isNot(contains('feature-squash-progressed')),
      );
    },
  );

  test(
    'getBranchesStatus returns correct upstream and isUpstreamGone',
    () async {
      // 1. Create a branch with no upstream
      await localGitDir.runCommand(['checkout', '-b', 'branch-no-upstream']);

      // 2. Create a branch with active upstream
      await localGitDir.runCommand(['checkout', '-b', 'branch-with-upstream']);
      await localGitDir.runCommand([
        'push',
        '-u',
        'origin',
        'branch-with-upstream',
      ]);

      // 3. Create a branch with gone upstream
      await localGitDir.runCommand(['checkout', '-b', 'branch-gone-upstream']);
      await localGitDir.runCommand([
        'push',
        '-u',
        'origin',
        'branch-gone-upstream',
      ]);
      final remoteGitDir = await GitDir.fromExisting(
        p.join(d.sandbox, 'remote'),
      );
      await remoteGitDir.runCommand(['branch', '-D', 'branch-gone-upstream']);
      await localGitDir.runCommand(['fetch', '--prune']);

      final status = await localGitDir.getBranchesStatus();

      final noUpstream = status['branch-no-upstream'];
      expect(noUpstream, isNotNull);
      expect(noUpstream!.upstream, isEmpty);
      expect(noUpstream.isUpstreamGone, isFalse);

      final withUpstream = status['branch-with-upstream'];
      expect(withUpstream, isNotNull);
      expect(
        withUpstream!.upstream,
        contains('refs/remotes/origin/branch-with-upstream'),
      );
      expect(withUpstream.isUpstreamGone, isFalse);

      final goneUpstream = status['branch-gone-upstream'];
      expect(goneUpstream, isNotNull);
      expect(goneUpstream!.isUpstreamGone, isTrue);
    },
  );

  test(
    'getBranchesStatus handles branch names containing pipe character',
    () async {
      const branchName = 'feature|pipe-branch';
      await localGitDir.runCommand(['checkout', '-b', branchName]);
      await localGitDir.runCommand(['push', '-u', 'origin', branchName]);

      final status = await localGitDir.getBranchesStatus();
      final branchStatus = status[branchName];
      expect(branchStatus, isNotNull);
      expect(
        branchStatus!.upstream,
        contains('refs/remotes/origin/$branchName'),
      );
      expect(branchStatus.isUpstreamGone, isFalse);
    },
  );

  test('gitUp with check: true warns if GitHub CLI is unavailable', () async {
    mockGhUnavailableForTesting = true;
    addTearDown(() => mockGhUnavailableForTesting = false);

    await localGitDir.runCommand(['checkout', '-b', 'feature-active']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-active']);

    await localGitDir.runCommand(['checkout', 'main']);

    await expectLater(
      () => wrappedForTesting(
        () => gitUp(workingDirectory: localPath, check: true),
      ),
      prints(
        allOf(
          contains(
            'Warning: GitHub CLI (gh) is not available or authenticated.',
          ),
          contains('Skipping active remote branch checks.'),
        ),
      ),
    );
  });

  test('gitUp with check: true warns if remote branch still exists', () async {
    mockGhAvailableForTesting = true;
    mockGhUnavailableForTesting = false;
    mockRecentPrsForTesting = {
      'feature-check': (
        state: 'CLOSED',
        url: 'https://github.com/kevmoo/scripts/pull/123',
        number: 123,
        baseBranch: 'main',
      ),
    };
    addTearDown(() {
      mockGhAvailableForTesting = false;
      mockRecentPrsForTesting = null;
    });

    await localGitDir.runCommand(['checkout', '-b', 'feature-check']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-check']);

    await localGitDir.runCommand(['checkout', 'main']);

    await expectLater(
      () => wrappedForTesting(
        () => gitUp(workingDirectory: localPath, check: true),
      ),
      prints(
        allOf(
          contains('Checking active remote branches for closed PRs...'),
          contains('PR #123 for branch "feature-check" is closed,'),
          contains('but the remote branch still exists.'),
        ),
      ),
    );
  });

  test(
    'gitUp with check: true does NOT warn if remote branch is deleted/pruned',
    () async {
      mockGhAvailableForTesting = true;
      mockGhUnavailableForTesting = false;
      mockRecentPrsForTesting = {
        'feature-check-deleted': (
          state: 'CLOSED',
          url: 'https://github.com/kevmoo/scripts/pull/123',
          number: 123,
          baseBranch: 'main',
        ),
      };
      addTearDown(() {
        mockGhAvailableForTesting = false;
        mockRecentPrsForTesting = null;
      });

      // 1. Create and push branch
      await localGitDir.runCommand(['checkout', '-b', 'feature-check-deleted']);
      await localGitDir.runCommand([
        'push',
        '-u',
        'origin',
        'feature-check-deleted',
      ]);

      // 2. Switch to main
      await localGitDir.runCommand(['checkout', 'main']);

      // 3. Delete remote branch on the "remote" repo
      final remoteGitDir = await GitDir.fromExisting(
        p.join(d.sandbox, 'remote'),
      );
      await remoteGitDir.runCommand(['branch', '-D', 'feature-check-deleted']);

      // 4. Run gitUp - this will fetch and prune, deleting origin/feature-check-deleted locally,
      // so the warning should NOT be printed!
      await expectLater(
        () => wrappedForTesting(
          () => gitUp(workingDirectory: localPath, check: true),
        ),
        prints(
          isNot(
            contains('PR #123 for branch "feature-check-deleted" is closed'),
          ),
        ),
      );
    },
  );

  test('gitUp cleans up local branches that have merged PRs '
      'even if their upstream is not gone', () async {
    mockGhAvailableForTesting = true;
    mockGhUnavailableForTesting = false;
    mockRecentPrsForTesting = {
      'feature-merged-active': (
        state: 'MERGED',
        url: 'https://github.com/kevmoo/scripts/pull/123',
        number: 123,
        baseBranch: 'main',
      ),
    };
    addTearDown(() {
      mockGhAvailableForTesting = false;
      mockRecentPrsForTesting = null;
    });

    // 1. Create a branch and push it (active upstream)
    await localGitDir.runCommand(['checkout', '-b', 'feature-merged-active']);
    await localGitDir.runCommand([
      'push',
      '-u',
      'origin',
      'feature-merged-active',
    ]);

    // 2. Switch back to main
    await localGitDir.runCommand(['checkout', 'main']);

    // 3. Run gitUp - should detect the merged PR and clean up the branch
    // locally, even though the remote branch is NOT deleted (since we did
    // not delete it on remote)!
    await expectLater(
      () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
      prints(
        allOf(
          contains('Checking safety of 1 branches with gone upstreams...'),
          contains('Deleting feature-merged-active...'),
        ),
      ),
    );

    // Verify it was deleted
    final branches = await localGitDir.branches();
    expect(
      branches.map((b) => b.branchName),
      isNot(contains('feature-merged-active')),
    );
  });

  test(
    'gitUp cleans up gone branches merged into a non-default branch',
    () async {
      mockGhAvailableForTesting = true;
      mockGhUnavailableForTesting = false;
      mockRecentPrsForTesting = {
        'feature-merged-non-default': (
          state: 'MERGED',
          url: 'https://github.com/kevmoo/scripts/pull/124',
          number: 124,
          baseBranch: 'feature-base',
        ),
      };
      addTearDown(() {
        mockGhAvailableForTesting = false;
        mockRecentPrsForTesting = null;
      });

      // 1. Create the base branch 'feature-base'
      await localGitDir.runCommand(['checkout', '-b', 'feature-base']);
      await localGitDir.runCommand(['push', '-u', 'origin', 'feature-base']);

      // 2. Create the feature branch 'feature-merged-non-default' from
      //    'feature-base'
      await localGitDir.runCommand([
        'checkout',
        '-b',
        'feature-merged-non-default',
      ]);
      final filePath = p.join(localPath, 'feature.txt');
      File(filePath).writeAsStringSync('feature content');
      await localGitDir.runCommand(['add', 'feature.txt']);
      await localGitDir.runCommand(['commit', '-m', 'Feature commit']);

      // 3. Push feature branch
      await localGitDir.runCommand([
        'push',
        '-u',
        'origin',
        'feature-merged-non-default',
      ]);

      // 4. Switch back to main
      await localGitDir.runCommand(['checkout', 'main']);

      // Delete the local base branch so it ONLY exists as origin/feature-base remote-tracking!
      await localGitDir.runCommand(['branch', '-D', 'feature-base']);

      // 5. Simulate merge of feature branch into 'feature-base' on remote
      final remoteGitDir = await GitDir.fromExisting(
        p.join(d.sandbox, 'remote'),
      );
      await remoteGitDir.runCommand(['checkout', 'feature-base']);
      final remoteFilePath = p.join(d.sandbox, 'remote', 'feature.txt');
      File(remoteFilePath).writeAsStringSync('feature content');
      await remoteGitDir.runCommand(['add', 'feature.txt']);
      await remoteGitDir.runCommand(['commit', '-m', 'Merged feature (#124)']);

      // 6. Delete remote feature branch
      await remoteGitDir.runCommand([
        'branch',
        '-D',
        'feature-merged-non-default',
      ]);

      // 7. Run gitUp - should fetch and prune, then detect that
      //    feature-merged-non-default is merged into origin/feature-base
      //    (since we resolve lookups and check origin/feature-base!).
      //    It should delete feature-merged-non-default silently.
      await expectLater(
        () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
        prints(
          allOf(
            contains('Checking safety of 1 branches with gone upstreams...'),
            contains('Deleting feature-merged-non-default...'),
          ),
        ),
      );

      // Verify it was deleted
      final branches = await localGitDir.branches();
      expect(
        branches.map((b) => b.branchName),
        isNot(contains('feature-merged-non-default')),
      );
    },
  );

  test('resolveLookups returns empty set when branchName is empty', () async {
    final refs = await localGitDir.resolveLookups('');
    expect(refs, isEmpty);
  });

  test(
    'gitUp falls back to default branch when PR baseBranch is empty',
    () async {
      mockGhAvailableForTesting = true;
      mockGhUnavailableForTesting = false;
      mockRecentPrsForTesting = {
        'feature-empty-base': (
          state: 'MERGED',
          url: 'https://github.com/kevmoo/scripts/pull/125',
          number: 125,
          baseBranch: '', // Empty base branch!
        ),
      };
      addTearDown(() {
        mockGhAvailableForTesting = false;
        mockRecentPrsForTesting = null;
      });

      // 1. Create and commit to feature-empty-base
      await localGitDir.runCommand(['checkout', '-b', 'feature-empty-base']);
      final filePath = p.join(localPath, 'empty_base.txt');
      File(filePath).writeAsStringSync('empty base content');
      await localGitDir.runCommand(['add', 'empty_base.txt']);
      await localGitDir.runCommand(['commit', '-m', 'Empty base commit']);

      // 2. Push to remote
      await localGitDir.runCommand([
        'push',
        '-u',
        'origin',
        'feature-empty-base',
      ]);

      // 3. Switch to main
      await localGitDir.runCommand(['checkout', 'main']);

      // 4. Simulate squash merge on remote main
      final remoteGitDir = await GitDir.fromExisting(
        p.join(d.sandbox, 'remote'),
      );
      final remoteFilePath = p.join(d.sandbox, 'remote', 'empty_base.txt');
      File(remoteFilePath).writeAsStringSync('empty base content');
      await remoteGitDir.runCommand(['add', 'empty_base.txt']);
      await remoteGitDir.runCommand([
        'commit',
        '-m',
        'Squashed PR empty base commit (#125)',
      ]);

      // 5. Delete remote branch feature-empty-base
      await remoteGitDir.runCommand(['branch', '-D', 'feature-empty-base']);

      // 6. Run gitUp - should fall back to main and clean up feature-empty-base
      await expectLater(
        () => wrappedForTesting(() => gitUp(workingDirectory: localPath)),
        prints(
          allOf(
            contains('Successfully updated main.'),
            contains('Checking safety of 1 branches with gone upstreams...'),
            contains('Deleting feature-empty-base...'),
          ),
        ),
      );

      // Verify it was deleted
      final branches = await localGitDir.branches();
      expect(
        branches.map((b) => b.branchName),
        isNot(contains('feature-empty-base')),
      );
    },
  );
}
