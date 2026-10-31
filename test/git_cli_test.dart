@TestOn('vm')
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/process_utils.dart';
import 'package:kevmoo_scripts/src/shared/git_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('parseWorktreeListPorcelain', () {
    test('parses bare, branch, detached, and locked worktree stanzas', () {
      const porcelain = '''
worktree /repos/sdk/.bare
bare

worktree /repos/sdk/core/main/sdk
HEAD 1111aaaa
branch refs/heads/main

worktree /repos/sdk/core/feat/sdk
HEAD 2222bbbb
branch refs/heads/agent/feat-x
locked Active local benchmark

worktree /repos/_repo-plain-lock
HEAD 3333cccc
branch refs/heads/plain-lock
locked

worktree /repos/_repo-detached
HEAD 4444dddd
detached
''';

      final records = parseWorktreeListPorcelain(porcelain);
      check(records).length.equals(5);

      check(records[0]).equals((
        path: '/repos/sdk/.bare',
        branch: '',
        sha: '',
        isBare: true,
        isDetached: false,
        isLocked: false,
        lockReason: null,
      ));
      check(records[1]).equals((
        path: '/repos/sdk/core/main/sdk',
        branch: 'main',
        sha: '1111aaaa',
        isBare: false,
        isDetached: false,
        isLocked: false,
        lockReason: null,
      ));
      check(records[2]).equals((
        path: '/repos/sdk/core/feat/sdk',
        branch: 'agent/feat-x',
        sha: '2222bbbb',
        isBare: false,
        isDetached: false,
        isLocked: true,
        lockReason: 'Active local benchmark',
      ));
      check(records[3]).equals((
        path: '/repos/_repo-plain-lock',
        branch: 'plain-lock',
        sha: '3333cccc',
        isBare: false,
        isDetached: false,
        isLocked: true,
        lockReason: null,
      ));
      check(records[4]).equals((
        path: '/repos/_repo-detached',
        branch: '',
        sha: '4444dddd',
        isBare: false,
        isDetached: true,
        isLocked: false,
        lockReason: null,
      ));
    });

    test('handles empty output and stanzas without trailing newline', () {
      check(parseWorktreeListPorcelain('')).isEmpty();
      check(parseWorktreeListPorcelain('   \n\n  ')).isEmpty();

      final single = parseWorktreeListPorcelain(
        'worktree /tmp/single\nHEAD abcd1234\nbranch refs/heads/dev',
      );
      check(single).single.equals((
        path: '/tmp/single',
        branch: 'dev',
        sha: 'abcd1234',
        isBare: false,
        isDetached: false,
        isLocked: false,
        lockReason: null,
      ));
    });
  });

  group('parseOriginHeadBranchOutput', () {
    test('strips origin/ prefix and rejects unresolved HEAD outputs', () {
      check(parseOriginHeadBranchOutput('origin/main\n')).equals('main');
      check(parseOriginHeadBranchOutput('origin/release/2.x'))
          .equals('release/2.x');
      check(parseOriginHeadBranchOutput('trunk\n')).equals('trunk');
      check(parseOriginHeadBranchOutput('')).isNull();
      check(parseOriginHeadBranchOutput('   ')).isNull();
      check(parseOriginHeadBranchOutput('HEAD\n')).isNull();
      check(parseOriginHeadBranchOutput('origin/HEAD\n')).isNull();
      check(parseOriginHeadBranchOutput('origin/')).isNull();
    });
  });

  group('GitCli against real git repositories', () {
    Future<String> createRepo(
      String name, {
      String initialBranch = 'main',
    }) async {
      await d.dir(name, [d.file('README.md', '# $name\n')]).create();
      final repoPath = p.join(d.sandbox, name);
      defaultGitCli
        ..runSync(['init', '-b', initialBranch], workingDirectory: repoPath)
        ..runSync([
          'config',
          'user.email',
          'test@example.com',
        ], workingDirectory: repoPath)
        ..runSync(['config', 'user.name', 'Tester'], workingDirectory: repoPath)
        ..runSync([
          'config',
          'commit.gpgsign',
          'false',
        ], workingDirectory: repoPath)
        ..runSync(['add', '.'], workingDirectory: repoPath)
        ..runSync(['commit', '-m', 'init'], workingDirectory: repoPath);
      return repoPath;
    }

    test(
      'propagates GIT_TERMINAL_PROMPT=0 and read-only GIT_OPTIONAL_LOCKS=0',
      () async {
        final repoPath = await createRepo('env_repo');
        const aliasSpec =
            r'alias.envprobe=!sh -c "printf %s:%s '
            r'\"${GIT_TERMINAL_PROMPT:-unset}\" '
            r'\"${GIT_OPTIONAL_LOCKS:-unset}\""';
        const probeArgs = ['-c', aliasSpec, 'envprobe'];

        final rwSync = defaultGitCli.runSync(
          probeArgs,
          workingDirectory: repoPath,
        );
        check(rwSync.stdout.toString()).equals('0:unset');

        final roSync = defaultGitCli.runSync(
          probeArgs,
          workingDirectory: repoPath,
          readOnly: true,
        );
        check(roSync.stdout.toString()).equals('0:0');

        final rwAsync = await defaultGitCli.run(
          probeArgs,
          workingDirectory: repoPath,
        );
        check(rwAsync.stdout.toString()).equals('0:unset');

        final roAsync = await defaultGitCli.run(
          probeArgs,
          workingDirectory: repoPath,
          readOnly: true,
        );
        check(roAsync.stdout.toString()).equals('0:0');

        final viaProcessUtils = defaultSyncProcessRunner(
          'git',
          probeArgs,
          workingDirectory: repoPath,
        );
        check(viaProcessUtils.stdout.toString()).equals('0:unset');
      },
      onPlatform: const {'windows': Skip('Uses POSIX sh alias probe')},
    );

    test(
      'resolves currentBranch, config, defaultBranch, dirty, and worktrees',
      () async {
        final originPath = await createRepo(
          'origin_master',
          initialBranch: 'master',
        );
        final clonePath = p.join(d.sandbox, 'clone_repo');
        defaultGitCli.runSync(['clone', originPath, clonePath]);

        check(defaultGitCli.currentBranchSync(clonePath)).equals('master');
        check(await defaultGitCli.currentBranch(clonePath)).equals('master');
        check(
          defaultGitCli.configGetSync(
            'remote.origin.url',
            workingDirectory: clonePath,
          ),
        ).equals(originPath);
        check(
          defaultGitCli.configGetSync(
            'nonexistent.key',
            workingDirectory: clonePath,
          ),
        ).isNull();

        // 1. origin/HEAD set -> resolves 'master'
        check(defaultGitCli.defaultBranchSync(clonePath)).equals('master');

        // 2. Delete origin/HEAD -> sniffs refs/remotes/origin/master
        defaultGitCli.runSync(const [
          'remote',
          'set-head',
          'origin',
          '-d',
        ], workingDirectory: clonePath);
        check(defaultGitCli.defaultBranchSync(clonePath)).equals('master');

        // 3. Repo with no origin remote -> returns fallback
        check(defaultGitCli.defaultBranchSync(originPath, fallback: 'custom'))
            .equals('custom');

        // 4. Detached HEAD -> currentBranch returns null
        defaultGitCli.runSync(const [
          'checkout',
          '--detach',
          'HEAD',
        ], workingDirectory: clonePath);
        check(defaultGitCli.currentBranchSync(clonePath)).isNull();
        check(await defaultGitCli.currentBranch(clonePath)).isNull();

        // 5. Worktrees & dirty state
        final wtPath = p.join(d.sandbox, '_clone_repo-feat');
        defaultGitCli
          ..runSync([
            'worktree',
            'add',
            '-b',
            'feat',
            wtPath,
          ], workingDirectory: clonePath)
          ..runSync([
            'worktree',
            'lock',
            '--reason',
            'Keep me',
            wtPath,
          ], workingDirectory: clonePath);

        final worktrees = defaultGitCli.listWorktreesSync(clonePath);
        check(worktrees).length.equals(2);
        final primaryWt = worktrees.firstWhere((w) => w.isDetached);
        check(primaryWt.branch).isEmpty();
        final linkedWt = worktrees.firstWhere((w) => w.branch == 'feat');
        check(linkedWt.isLocked).isTrue();
        check(linkedWt.lockReason).equals('Keep me');

        check(defaultGitCli.isDirtySync(wtPath)).isFalse();
        File(p.join(wtPath, 'untracked.txt')).writeAsStringSync('scratch');
        check(defaultGitCli.isDirtySync(wtPath)).isFalse();
        check(defaultGitCli.isDirtySync(wtPath, includeUntracked: true))
            .isTrue();
        check(await defaultGitCli.isDirty(wtPath, includeUntracked: true))
            .isTrue();
      },
    );

    test('supports custom injected runners and handles exceptions', () async {
      final recorded = <List<String>>[];
      final fakeCli = GitCli(
        syncRunner: (exe, args, {workingDirectory}) {
          check(exe).equals('git');
          recorded.add(args);
          if (args.contains('boom')) {
            throw const ProcessException('git', ['boom'], 'failed');
          }
          return ProcessResult(0, 0, '  hello-sync  \n', '');
        },
        asyncRunner: (exe, args, {workingDirectory}) async {
          check(exe).equals('git');
          recorded.add(args);
          if (args.contains('boom')) {
            throw const ProcessException('git', ['boom'], 'failed');
          }
          return ProcessResult(0, 0, '  hello-async  \n', '');
        },
      );

      check(fakeCli.stdoutOrNullSync(const ['rev-parse', 'HEAD']))
          .equals('hello-sync');
      check(await fakeCli.stdoutOrNull(const ['rev-parse', 'HEAD']))
          .equals('hello-async');
      check(fakeCli.stdoutOrNullSync(const ['boom'])).isNull();
      check(await fakeCli.stdoutOrNull(const ['boom'])).isNull();
      check(fakeCli.checkSync(const ['boom'])).isFalse();
      check(await fakeCli.check(const ['boom'])).isFalse();
      check(fakeCli.isDirtySync('/fake', failClosedOnProcessError: true))
          .isTrue();
      check(recorded).length.equals(7);
    });
  });
}
