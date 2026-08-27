import 'dart:io';

import 'package:checks/checks.dart';
import 'package:git/git.dart';
import 'package:kevmoo_scripts/src/gh_clean.dart';
import 'package:kevmoo_scripts/src/git_extensions.dart';
import 'package:kevmoo_scripts/src/local_repo_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('buildLandedSearchQuery', () {
    test('builds query with user and no repo', () {
      final q = buildLandedSearchQuery(user: 'kevmoo');
      check(q).equals('is:pr is:merged author:kevmoo sort:updated-desc');
    });

    test('builds query with repo and date filter', () {
      final fixedDate = DateTime(2026, 8, 27);
      final q = buildLandedSearchQuery(
        user: 'kevmoo',
        repo: 'invertase/melos',
        lastNDays: 7,
        now: fixedDate,
      );
      check(q).equals(
        'is:pr is:merged author:kevmoo repo:invertase/melos merged:>=2026-08-20 sort:updated-desc',
      );
    });
  });

  group('parseLandedPrNode', () {
    test('parses full GraphQL PR node', () {
      final node = {
        'number': 1063,
        'title': 'feat: avoid cascading releases',
        'url': 'https://github.com/invertase/melos/pull/1063',
        'state': 'MERGED',
        'mergedAt': '2026-08-25T08:03:58Z',
        'closedAt': '2026-08-25T08:03:58Z',
        'headRefName': 'feat/version-no-cascade',
        'headRefOid': 'abc1234',
        'baseRefName': 'main',
        'repository': {
          'nameWithOwner': 'invertase/melos',
          'url': 'https://github.com/invertase/melos',
          'isArchived': false,
        },
        'mergeCommit': {'oid': 'bf3c27b7b4b3247df9d684a8621c8121bf496995'},
      };

      final pr = parseLandedPrNode(node);
      check(pr).isNotNull();
      check(pr!.number).equals(1063);
      check(pr.title).equals('feat: avoid cascading releases');
      check(pr.repository).equals('invertase/melos');
      check(pr.headRefName).equals('feat/version-no-cascade');
      check(pr.baseRefName).equals('main');
      check(pr.mergeSha).equals('bf3c27b7b4b3247df9d684a8621c8121bf496995');
    });

    test('returns null when required fields are missing', () {
      final node = {'number': 1063};
      check(parseLandedPrNode(node)).isNull();
    });
  });

  group('planCleanup', () {
    final samplePr = (
      number: 1063,
      title: 'feat: new versioning',
      url: 'https://github.com/invertase/melos/pull/1063',
      repository: 'invertase/melos',
      repoUrl: 'https://github.com/invertase/melos',
      headRefName: 'feat-branch',
      headRefOid: '123',
      baseRefName: 'main',
      mergeSha: '456',
      mergedAt: DateTime.now(),
      closedAt: DateTime.now(),
    );

    test('returns empty list when repo is not cloned locally', () {
      final plan = planCleanup(samplePr, null);
      check(plan).isEmpty();
    });

    test('plans branch deletion and sync when local branch exists', () {
      final localRepo = (
        repoName: 'invertase/melos',
        repoPath: '/path/to/melos',
        currentBranch: 'main',
        branches: [(name: 'feat-branch', sha: '123')],
        worktrees: <LocalWorktreeEntry>[],
      );

      final plan = planCleanup(samplePr, localRepo);
      check(plan)
        ..contains('Delete local branch `feat-branch`')
        ..contains('Sync `main` to `origin/main`');
    });

    test('plans worktree pruning when worktree exists', () {
      final localRepo = (
        repoName: 'invertase/melos',
        repoPath: '/path/to/melos',
        currentBranch: 'main',
        branches: [(name: 'main', sha: '000')],
        worktrees: [
          (
            path: '/path/to/_melos-feat-branch',
            branch: 'feat-branch',
            sha: '123',
          ),
        ],
      );

      final plan = planCleanup(
        samplePr,
        localRepo,
        processRunner: (exe, args, {workingDirectory}) =>
            ProcessResult(0, 0, '', ''),
      );
      check(plan).contains('Prune worktree at /path/to/_melos-feat-branch');
    });

    test('planCleanup skips dirty worktrees', () {
      final localRepo = (
        repoName: 'invertase/melos',
        repoPath: '/path/to/melos',
        currentBranch: 'main',
        branches: [(name: 'main', sha: '000')],
        worktrees: [
          (
            path: '/path/to/_melos-feat-branch',
            branch: 'feat-branch',
            sha: '123',
          ),
        ],
      );

      final plan = planCleanup(
        samplePr,
        localRepo,
        processRunner: (exe, args, {workingDirectory}) =>
            ProcessResult(0, 0, ' M dirty.txt\n', ''),
      );
      check(plan).contains(
        'Skip worktree at /path/to/_melos-feat-branch (has uncommitted changes)',
      );
    });
  });

  group('executeCleanup integration test', () {
    test('removes worktree, deletes branch, and syncs main', () async {
      // 1. Create a remote repo with base commit and updated main commit
      await d.dir('remote', [d.file('README.md', 'remote readme')]).create();
      final remotePath = p.join(d.sandbox, 'remote');
      final remoteGit = await GitDir.init(remotePath, allowContent: true);
      await remoteGit.configureTestIdentity();
      await remoteGit.runCommand(['branch', '-M', 'main']);
      await remoteGit.runCommand(['add', '.']);
      await remoteGit.runCommand(['commit', '-m', 'init']);

      // 2. Clone to local
      final localPath = p.join(d.sandbox, 'local');
      await Process.run('git', ['clone', remotePath, localPath]);
      final localGit = await GitDir.fromExisting(localPath);
      await localGit.configureTestIdentity();

      // 3. Create feature branch and attached worktree in local
      final wtPath = p.join(d.sandbox, '_local-feature-x');
      await localGit.runCommand(['worktree', 'add', '-b', 'feature-x', wtPath]);

      // 4. Add a new commit to remote main to simulate merged PR
      await File(p.join(remotePath, 'merged.txt'))
          .writeAsString('merged content');
      await remoteGit.runCommand(['add', '.']);
      await remoteGit.runCommand(['commit', '-m', 'Merge PR #1']);

      final landedPr = (
        number: 1,
        title: 'Feature X',
        url: 'https://github.com/test/local/pull/1',
        repository: 'test/local',
        repoUrl: 'https://github.com/test/local',
        headRefName: 'feature-x',
        headRefOid: '111',
        baseRefName: 'main',
        mergeSha: '222',
        mergedAt: DateTime.now(),
        closedAt: DateTime.now(),
      );

      final localInfo = (
        repoName: 'test/local',
        repoPath: localPath,
        currentBranch: 'main',
        branches: [(name: 'feature-x', sha: '111'), (name: 'main', sha: '000')],
        worktrees: [(path: wtPath, branch: 'feature-x', sha: '111')],
      );

      final actions = executeCleanup(landedPr, localInfo);
      check(actions.every((a) => a.success)).isTrue();

      // Worktree directory should be gone
      check(Directory(wtPath).existsSync()).isFalse();

      // Branch should be deleted
      final branchList = await localGit.runCommand(['branch', '--list']);
      check(branchList.stdout as String).not((it) => it.contains('feature-x'));

      // Main should be fast-forwarded to include merged.txt
      check(File(p.join(localPath, 'merged.txt')).existsSync()).isTrue();
    });
  });

  group('Reports formatting', () {
    test('formatMarkdownReport formats table correctly', () {
      final pr = (
        number: 1063,
        title: 'feat: no cascade',
        url: 'https://github.com/invertase/melos/pull/1063',
        repository: 'invertase/melos',
        repoUrl: 'https://github.com/invertase/melos',
        headRefName: 'feat-no-cascade',
        headRefOid: '123',
        baseRefName: 'main',
        mergeSha: '456',
        mergedAt: DateTime.utc(2026, 8, 25, 8, 3),
        closedAt: DateTime.utc(2026, 8, 25, 8, 3),
      );

      final result = (
        pr: pr,
        localRepo: (
          repoName: 'invertase/melos',
          repoPath: '/home/user/github/melos',
          currentBranch: 'main',
          branches: <LocalBranchEntry>[],
          worktrees: <LocalWorktreeEntry>[],
        ),
        plannedActions: [
          'Prune worktree at /home/user/github/_melos-feat',
          'Sync `main`',
        ],
        executedActions: <CleanAction>[],
        status: 'Pending',
      );

      final report = formatMarkdownReport([result], applied: false);
      check(report)
        ..contains('# Landed Pull Requests Cleanup Report')
        ..contains('🔍 Preview Mode (Dry Run)')
        ..contains('[**invertase/melos**](https://github.com/invertase/melos)')
        ..contains('[#1063](https://github.com/invertase/melos/pull/1063)')
        ..contains(
          '• Prune worktree at /home/user/github/_melos-feat<br>• Sync `main`',
        );
    });

    test('formatJsonReport produces valid JSON schema', () {
      final pr = (
        number: 1063,
        title: 'feat: no cascade',
        url: 'https://github.com/invertase/melos/pull/1063',
        repository: 'invertase/melos',
        repoUrl: 'https://github.com/invertase/melos',
        headRefName: 'feat-no-cascade',
        headRefOid: '123',
        baseRefName: 'main',
        mergeSha: '456',
        mergedAt: DateTime.utc(2026, 8, 25, 8, 3),
        closedAt: DateTime.utc(2026, 8, 25, 8, 3),
      );

      final result = (
        pr: pr,
        localRepo: null,
        plannedActions: <String>[],
        executedActions: <CleanAction>[],
        status: 'Not cloned locally',
      );

      final json = formatJsonReport([result], applied: false);
      check(json['total']).equals(1);
      check(json['applied']).equals(false);
      final resultsList = json['results'] as List<dynamic>;
      check(resultsList.length).equals(1);
    });
  });
}
