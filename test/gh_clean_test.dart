import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:git/git.dart';
import 'package:kevmoo_scripts/src/gh_clean.dart';
import 'package:kevmoo_scripts/src/git_extensions.dart';
import 'package:kevmoo_scripts/src/local_repo_scanner.dart';
import 'package:kevmoo_scripts/src/process_utils.dart';
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

    test('throws ArgumentError when lastNDays is zero or negative', () {
      check(() => buildLandedSearchQuery(user: 'kevmoo', lastNDays: 0))
          .throws<ArgumentError>();
      check(() => buildLandedSearchQuery(user: 'kevmoo', lastNDays: -5))
          .throws<ArgumentError>();
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
    final samplePr = LandedPr(
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

    test('plans branch deletion and sync when local branch exists and trunk is '
        'behind', () {
      final localRepo = (
        repoName: 'invertase/melos',
        repoNames: ['invertase/melos'],
        repoPath: '/path/to/melos',
        currentBranch: 'main',
        branches: [
          (
            name: 'feat-branch',
            sha: '123',
            upstream: null,
            upstreamTrack: null,
          ),
          (
            name: 'main',
            sha: '000',
            upstream: 'origin/main',
            upstreamTrack: '[behind 1]',
          ),
        ],
        worktrees: <LocalWorktreeEntry>[],
      );

      final plan = planCleanup(samplePr, localRepo);
      check(plan)
        ..contains('Delete local branch `feat-branch`')
        ..contains('Sync `main` to `origin/main`');
    });

    test('omits trunk sync when main is already up to date with upstream', () {
      final localRepo = (
        repoName: 'invertase/melos',
        repoNames: ['invertase/melos'],
        repoPath: '/path/to/melos',
        currentBranch: 'main',
        branches: [
          (
            name: 'feat-branch',
            sha: '123',
            upstream: null,
            upstreamTrack: null,
          ),
          (
            name: 'main',
            sha: '123',
            upstream: 'origin/main',
            upstreamTrack: '',
          ),
        ],
        worktrees: <LocalWorktreeEntry>[],
      );

      final plan = planCleanup(samplePr, localRepo);
      check(plan)
        ..contains('Delete local branch `feat-branch`')
        ..not((it) => it.contains('Sync `main` to `origin/main`'));
    });

    test('plans worktree pruning when worktree exists', () {
      final localRepo = (
        repoName: 'invertase/melos',
        repoNames: ['invertase/melos'],
        repoPath: '/path/to/melos',
        currentBranch: 'main',
        branches: [
          (
            name: 'main',
            sha: '000',
            upstream: 'origin/main',
            upstreamTrack: '',
          ),
        ],
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
        repoNames: ['invertase/melos'],
        repoPath: '/path/to/melos',
        currentBranch: 'main',
        branches: [
          (
            name: 'main',
            sha: '000',
            upstream: 'origin/main',
            upstreamTrack: '',
          ),
        ],
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

      final landedPr = LandedPr(
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
        repoNames: ['test/local'],
        repoPath: localPath,
        currentBranch: 'main',
        branches: [
          (name: 'feature-x', sha: '111', upstream: null, upstreamTrack: null),
          (
            name: 'main',
            sha: '000',
            upstream: 'origin/main',
            upstreamTrack: '[behind 1]',
          ),
        ],
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

    test(
      'deletes squash-merged branch when local branch is advanced onto squash '
      'commit',
      () async {
        // 1. Create a remote repo with base commit
        await d.dir('remote-squash', [
          d.file('README.md', 'remote readme'),
        ]).create();
        final remotePath = p.join(d.sandbox, 'remote-squash');
        final remoteGit = await GitDir.init(remotePath, allowContent: true);
        await remoteGit.configureTestIdentity();
        await remoteGit.runCommand(['branch', '-M', 'main']);
        await remoteGit.runCommand(['add', '.']);
        await remoteGit.runCommand(['commit', '-m', 'init']);

        // 2. Clone to local
        final localPath = p.join(d.sandbox, 'local-squash');
        await Process.run('git', ['clone', remotePath, localPath]);
        final localGit = await GitDir.fromExisting(localPath);
        await localGit.configureTestIdentity();

        // 3. Create feature branch in local with a commit
        await localGit.runCommand(['checkout', '-b', 'feature-squash']);
        await File(p.join(localPath, 'feature.txt'))
            .writeAsString('feature content');
        await localGit.runCommand(['add', '.']);
        await localGit.runCommand(['commit', '-m', 'feature commit']);
        final prHeadOid = (await localGit.runCommand(['rev-parse', 'HEAD']))
            .stdout
            .toString()
            .trim();

        // 4. On remote, create squash merge commit on main
        await File(p.join(remotePath, 'feature.txt'))
            .writeAsString('feature content');
        await remoteGit.runCommand(['add', '.']);
        await remoteGit.runCommand(['commit', '-m', 'Squash commit (#1)']);

        // 5. Point local feature branch at the squash commit without fetching
        // origin/main into local git tracking, proving executeCleanup fetches
        // and updates trunk before branch containment check.
        final squashSha = (await remoteGit.runCommand(['rev-parse', 'HEAD']))
            .stdout
            .toString()
            .trim();
        await localGit.runCommand(['fetch', remotePath, 'main']);
        await localGit.runCommand([
          'update-ref',
          'refs/heads/feature-squash',
          squashSha,
        ]);
        await localGit.runCommand(['checkout', 'main']);

        final landedPr = LandedPr(
          number: 1,
          title: 'Squash Feature',
          url: 'https://github.com/test/local-squash/pull/1',
          repository: 'test/local-squash',
          repoUrl: 'https://github.com/test/local-squash',
          headRefName: 'feature-squash',
          headRefOid: prHeadOid,
          baseRefName: 'main',
          mergedAt: DateTime.now(),
          closedAt: DateTime.now(),
        );

        final localInfo = (
          repoName: 'test/local-squash',
          repoNames: ['test/local-squash'],
          repoPath: localPath,
          currentBranch: 'main',
          branches: [
            (
              name: 'feature-squash',
              sha: '999',
              upstream: null,
              upstreamTrack: null,
            ),
            (
              name: 'main',
              sha: '000',
              upstream: 'origin/main',
              upstreamTrack: '',
            ),
          ],
          worktrees: <LocalWorktreeEntry>[],
        );

        final actions = executeCleanup(landedPr, localInfo);
        check(actions.every((a) => a.success)).isTrue();

        // Branch should be deleted successfully without false positive error
        final branchList = await localGit.runCommand(['branch', '--list']);
        check(branchList.stdout as String)
            .not((it) => it.contains('feature-squash'));
      },
    );

    test(
      'refuses to delete branch with unpushed commits not in trunk',
      () async {
        // 1. Create a remote repo with base commit
        await d.dir('remote-unpushed', [
          d.file('README.md', 'remote readme'),
        ]).create();
        final remotePath = p.join(d.sandbox, 'remote-unpushed');
        final remoteGit = await GitDir.init(remotePath, allowContent: true);
        await remoteGit.configureTestIdentity();
        await remoteGit.runCommand(['branch', '-M', 'main']);
        await remoteGit.runCommand(['add', '.']);
        await remoteGit.runCommand(['commit', '-m', 'init']);

        // 2. Clone to local
        final localPath = p.join(d.sandbox, 'local-unpushed');
        await Process.run('git', ['clone', remotePath, localPath]);
        final localGit = await GitDir.fromExisting(localPath);
        await localGit.configureTestIdentity();

        // 3. Create feature branch in local with PR commit
        await localGit.runCommand(['checkout', '-b', 'feature-unpushed']);
        await File(p.join(localPath, 'feature.txt'))
            .writeAsString('pr content');
        await localGit.runCommand(['add', '.']);
        await localGit.runCommand(['commit', '-m', 'pr commit']);
        final prHeadOid = (await localGit.runCommand(['rev-parse', 'HEAD']))
            .stdout
            .toString()
            .trim();

        // 4. Add unpushed extra commit on top of PR commit
        await File(p.join(localPath, 'unpushed.txt'))
            .writeAsString('extra content');
        await localGit.runCommand(['add', '.']);
        await localGit.runCommand(['commit', '-m', 'unpushed extra commit']);
        await localGit.runCommand(['checkout', 'main']);

        final landedPr = LandedPr(
          number: 1,
          title: 'Unpushed Feature',
          url: 'https://github.com/test/local-unpushed/pull/1',
          repository: 'test/local-unpushed',
          repoUrl: 'https://github.com/test/local-unpushed',
          headRefName: 'feature-unpushed',
          headRefOid: prHeadOid,
          baseRefName: 'main',
          mergedAt: DateTime.now(),
          closedAt: DateTime.now(),
        );

        final localInfo = (
          repoName: 'test/local-unpushed',
          repoNames: ['test/local-unpushed'],
          repoPath: localPath,
          currentBranch: 'main',
          branches: [
            (
              name: 'feature-unpushed',
              sha: '999',
              upstream: null,
              upstreamTrack: null,
            ),
            (
              name: 'main',
              sha: '000',
              upstream: 'origin/main',
              upstreamTrack: '',
            ),
          ],
          worktrees: <LocalWorktreeEntry>[],
        );

        final actions = executeCleanup(landedPr, localInfo);
        check(
          actions.any(
            (a) =>
                !a.success &&
                a.error != null &&
                a.error!.contains('unpushed commits'),
          ),
        ).isTrue();

        // Branch should NOT be deleted
        final branchList = await localGit.runCommand(['branch', '--list']);
        check(branchList.stdout as String).contains('feature-unpushed');
      },
    );

    test('integration test refuses to delete branch when not in trunk and '
        'headRefOid is empty', () async {
      final remotePath = p.join(d.sandbox, 'remote-empty-head');
      await Directory(remotePath).create();
      final remoteGit = await GitDir.init(remotePath, allowContent: true);
      await remoteGit.configureTestIdentity();
      await remoteGit.runCommand(['branch', '-M', 'main']);
      await File(p.join(remotePath, 'init.txt')).writeAsString('init');
      await remoteGit.runCommand(['add', '.']);
      await remoteGit.runCommand(['commit', '-m', 'init']);

      final localPath = p.join(d.sandbox, 'local-empty-head');
      await Process.run('git', ['clone', remotePath, localPath]);
      final localGit = await GitDir.fromExisting(localPath);
      await localGit.configureTestIdentity();

      await localGit.runCommand(['checkout', '-b', 'feature-empty-head']);
      await File(p.join(localPath, 'f.txt')).writeAsString('local only');
      await localGit.runCommand(['add', '.']);
      await localGit.runCommand(['commit', '-m', 'unmerged local commit']);
      await localGit.runCommand(['checkout', 'main']);

      final landedPr = LandedPr(
        number: 1,
        title: 'Empty Head PR',
        url: 'https://github.com/test/local-empty-head/pull/1',
        repository: 'test/local-empty-head',
        repoUrl: 'https://github.com/test/local-empty-head',
        headRefName: 'feature-empty-head',
        headRefOid: '',
        baseRefName: 'main',
        mergedAt: DateTime.now(),
        closedAt: DateTime.now(),
      );

      final localInfo = (
        repoName: 'test/local-empty-head',
        repoNames: ['test/local-empty-head'],
        repoPath: localPath,
        currentBranch: 'main',
        branches: [
          (
            name: 'feature-empty-head',
            sha: '999',
            upstream: null,
            upstreamTrack: null,
          ),
          (
            name: 'main',
            sha: '000',
            upstream: 'origin/main',
            upstreamTrack: '',
          ),
        ],
        worktrees: <LocalWorktreeEntry>[],
      );

      final actions = executeCleanup(landedPr, localInfo);
      check(
        actions.any(
          (a) =>
              !a.success &&
              a.error != null &&
              a.error!.contains('empty headRefOid'),
        ),
      ).isTrue();

      final branchList = await localGit.runCommand(['branch', '--list']);
      check(branchList.stdout as String).contains('feature-empty-head');
    });
  });

  group('Reports formatting', () {
    test('formatMarkdownReport formats table correctly', () {
      final pr = LandedPr(
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
          repoNames: ['invertase/melos'],
          repoPath: '/home/user/github/melos',
          currentBranch: 'main',
          branches: <LocalBranchEntry>[],
          worktrees: <LocalWorktreeEntry>[],
        ),
        plannedActions: [
          'Prune worktree at /home/user/github/_melos-feat',
          'Sync `main` to `origin/main`',
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

    test('formatMarkdownReport sorts by org -> repo -> oldest PR number', () {
      final prKevmoo8 = LandedPr(
        number: 8,
        title: 'pr 8',
        url: 'https://github.com/kevmoo/private_life/pull/8',
        repository: 'kevmoo/private_life',
        repoUrl: 'https://github.com/kevmoo/private_life',
        headRefName: 'branch-8',
        headRefOid: '888',
        baseRefName: 'main',
        mergeSha: '888',
        mergedAt: DateTime.utc(2026, 8, 25),
        closedAt: DateTime.utc(2026, 8, 25),
      );

      final prDart1 = LandedPr(
        number: 1,
        title: 'pr 1',
        url: 'https://github.com/dart-lang/ecosystem/pull/1',
        repository: 'dart-lang/ecosystem',
        repoUrl: 'https://github.com/dart-lang/ecosystem',
        headRefName: 'branch-1',
        headRefOid: '111',
        baseRefName: 'main',
        mergeSha: '111',
        mergedAt: DateTime.utc(2026, 8, 25),
        closedAt: DateTime.utc(2026, 8, 25),
      );

      final report = formatMarkdownReport([
        (
          pr: prKevmoo8,
          localRepo: null,
          plannedActions: <String>[],
          executedActions: <CleanAction>[],
          status: 'Not cloned locally',
        ),
        (
          pr: prDart1,
          localRepo: null,
          plannedActions: <String>[],
          executedActions: <CleanAction>[],
          status: 'Not cloned locally',
        ),
      ], applied: false);

      final dartIndex = report.indexOf('dart-lang/ecosystem');
      final kevmooIndex = report.indexOf('kevmoo/private_life');
      check(dartIndex).isLessThan(kevmooIndex);
    });

    test('formatJsonReport produces valid JSON schema', () {
      final pr = LandedPr(
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

    test('fetchLandedPrs excludes Dart SDK and fork repositories', () async {
      final mockJson = jsonEncode({
        'data': {
          'search': {
            'nodes': [
              {
                'number': 32,
                'title': 'feat: vm parseUtf8 intrinsic',
                'url': 'https://github.com/kevmoo/sdk/pull/32',
                'state': 'MERGED',
                'headRefName': 'json-utf8-decode',
                'headRefOid': 'abc1234',
                'baseRefName': 'main',
                'repository': {
                  'nameWithOwner': 'kevmoo/sdk',
                  'url': 'https://github.com/kevmoo/sdk',
                  'isArchived': false,
                },
                'mergeCommit': {'oid': '1234567890abcdef'},
              },
              {
                'number': 100,
                'title': 'feat: dart-lang sdk fix',
                'url': 'https://github.com/dart-lang/sdk/pull/100',
                'state': 'MERGED',
                'headRefName': 'fix-branch',
                'headRefOid': 'def5678',
                'baseRefName': 'main',
                'repository': {
                  'nameWithOwner': 'dart-lang/sdk',
                  'url': 'https://github.com/dart-lang/sdk',
                  'isArchived': false,
                },
                'mergeCommit': {'oid': 'abcdef1234567890'},
              },
              {
                'number': 445,
                'title': 'feat: ecosystem feature',
                'url': 'https://github.com/dart-lang/ecosystem/pull/445',
                'state': 'MERGED',
                'headRefName': 'feat-eco',
                'headRefOid': '9998887',
                'baseRefName': 'main',
                'repository': {
                  'nameWithOwner': 'dart-lang/ecosystem',
                  'url': 'https://github.com/dart-lang/ecosystem',
                  'isArchived': false,
                },
                'mergeCommit': {'oid': '1112223334445556'},
              },
            ],
          },
        },
      });

      final prs = await fetchLandedPrs(
        user: 'kevmoo',
        processRunner: (exe, args, {workingDirectory}) =>
            ProcessResult(1, 0, mockJson, ''),
      );

      check(prs.map((p) => p.repository))
        ..contains('dart-lang/ecosystem')
        ..not((it) => it.contains('kevmoo/sdk'))
        ..not((it) => it.contains('dart-lang/sdk'));
    });

    test('fetchLandedPrs paginates in chunks of 50 when limit > 50', () async {
      String? passedLimit;
      final mockJson = jsonEncode({
        'data': {
          'search': {
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
            'nodes': <dynamic>[],
          },
        },
      });

      await fetchLandedPrs(
        user: 'kevmoo',
        limit: 200,
        processRunner: (exe, args, {workingDirectory}) {
          for (final arg in args) {
            if (arg.startsWith('limit=')) {
              passedLimit = arg.substring('limit='.length);
            }
          }
          return ProcessResult(1, 0, mockJson, '');
        },
      );

      check(passedLimit).equals('50');
    });

    test('formatMarkdownReport formats unlinked worktrees table correctly', () {
      final unlinked = [
        (
          repository: 'dart-lang/build',
          worktreePath: '/home/user/github/_build-pr-5098',
          branch: 'pr-5098',
          sha: '2e45f6dd',
          commitsAhead: 17,
          lastCommitDate: '2026-09-02',
          lastCommitSubject: 'Add contracts',
        ),
      ];

      final report = formatMarkdownReport(
        [],
        applied: false,
        unlinkedWorktrees: unlinked,
      );
      check(report)
        ..contains('## Worktrees with No Associated PR')
        ..contains('[**dart-lang/build**](https://github.com/dart-lang/build)')
        ..contains(
          '[`_build-pr-5098`](file:///home/user/github/_build-pr-5098)',
        )
        ..contains('`pr-5098`')
        ..contains('| 17 |')
        ..contains('| 2026-09-02 |');
    });

    test('formatJsonReport includes unlinkedWorktrees', () {
      final unlinked = [
        (
          repository: 'dart-lang/build',
          worktreePath: '/home/user/github/_build-pr-5098',
          branch: 'pr-5098',
          sha: '2e45f6dd',
          commitsAhead: 17,
          lastCommitDate: '2026-09-02',
          lastCommitSubject: 'Add contracts',
        ),
      ];

      final json = formatJsonReport(
        [],
        applied: false,
        unlinkedWorktrees: unlinked,
      );
      check(json['unlinkedWorktrees']).isA<List<dynamic>>();
      final list = json['unlinkedWorktrees'] as List<dynamic>;
      check(list.length).equals(1);
      final item = list.first as Map<String, dynamic>;
      check(item['repository']).equals('dart-lang/build');
      check(item['branch']).equals('pr-5098');
      check(item['commitsAhead']).equals(17);
      check(item['lastCommitDate']).equals('2026-09-02');
      check(item['lastCommitSubject']).equals('Add contracts');
    });
  });

  group('findUnlinkedWorktrees', () {
    test(
      'identifies secondary worktrees with no matching PR on GitHub',
      () async {
        await d.dir('repo_unlinked', [
          d.file('README.md', '# Unlinked'),
        ]).create();
        final repoPath = p.join(d.sandbox, 'repo_unlinked');
        final git = await GitDir.init(repoPath, allowContent: true);
        await git.configureTestIdentity();
        await git.runCommand(['branch', '-M', 'main']);
        await git.runCommand([
          'remote',
          'add',
          'origin',
          'https://github.com/dart-lang/build.git',
        ]);
        await git.runCommand(['add', '.']);
        await git.runCommand(['commit', '-m', 'init']);

        final wtPath = p.join(d.sandbox, '_build-pr-5098');
        await git.runCommand(['worktree', 'add', '-b', 'pr-5098', wtPath]);
        final wtGit = await GitDir.fromExisting(wtPath);
        await wtGit.configureTestIdentity();
        await File(p.join(wtPath, 'contract.txt'))
            .writeAsString('contract code');
        await wtGit.runCommand(['add', '.']);
        await wtGit.runCommand(['commit', '-m', 'Add contracts']);

        final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

        final unlinked = await findUnlinkedWorktrees(
          localRepos,
          <String>{},
          processRunner: (exe, args, {workingDirectory}) {
            if (exe == 'gh') {
              return ProcessResult(
                1,
                0,
                jsonEncode({
                  'data': {
                    'q0': {
                      'pullRequests': {'nodes': <dynamic>[]},
                    },
                  },
                }),
                '',
              );
            }
            return defaultSyncProcessRunner(
              exe,
              args,
              workingDirectory: workingDirectory,
            );
          },
        );

        check(unlinked.length).equals(1);
        final entry = unlinked.first;
        check(entry.repository).equals('dart-lang/build');
        check(entry.branch).equals('pr-5098');
        check(entry.worktreePath).equals(wtPath);
        check(entry.commitsAhead).isNotNull().equals(1);
        check(entry.lastCommitSubject).isNotNull().equals('Add contracts');
      },
    );

    test('excludes secondary worktrees that have an open PR', () async {
      await d.dir('repo_with_pr', [d.file('README.md', '# With PR')]).create();
      final repoPath = p.join(d.sandbox, 'repo_with_pr');
      final git = await GitDir.init(repoPath, allowContent: true);
      await git.configureTestIdentity();
      await git.runCommand(['branch', '-M', 'main']);
      await git.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/flutter/flutter.git',
      ]);
      await git.runCommand(['add', '.']);
      await git.runCommand(['commit', '-m', 'init']);

      final wtPath = p.join(d.sandbox, '_flutter-open-pr');
      await git.runCommand(['worktree', 'add', '-b', 'open-pr', wtPath]);

      final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

      final unlinked = await findUnlinkedWorktrees(
        localRepos,
        <String>{},
        processRunner: (exe, args, {workingDirectory}) {
          if (exe == 'gh') {
            return ProcessResult(
              1,
              0,
              jsonEncode({
                'data': {
                  'q0': {
                    'pullRequests': {
                      'nodes': [
                        {'number': 12345, 'state': 'OPEN'},
                      ],
                    },
                  },
                },
              }),
              '',
            );
          }
          return defaultSyncProcessRunner(
            exe,
            args,
            workingDirectory: workingDirectory,
          );
        },
      );

      check(unlinked).isEmpty();
    });

    test(
      'excludes worktrees that are already in matchedWorktreePaths',
      () async {
        await d.dir('repo_matched', [
          d.file('README.md', '# Matched'),
        ]).create();
        final repoPath = p.join(d.sandbox, 'repo_matched');
        final git = await GitDir.init(repoPath, allowContent: true);
        await git.configureTestIdentity();
        await git.runCommand(['branch', '-M', 'main']);
        await git.runCommand([
          'remote',
          'add',
          'origin',
          'https://github.com/dart-lang/test.git',
        ]);
        await git.runCommand(['add', '.']);
        await git.runCommand(['commit', '-m', 'init']);

        final wtPath = p.join(d.sandbox, '_test-matched');
        await git.runCommand([
          'worktree',
          'add',
          '-b',
          'matched-branch',
          wtPath,
        ]);

        final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

        final unlinked = await findUnlinkedWorktrees(
          localRepos,
          {wtPath}, // already matched
        );

        check(unlinked).isEmpty();
      },
    );

    test('never deletes unlinked worktrees under runGhClean --apply', () async {
      await d.dir('repo_safe', [d.file('README.md', '# Safe')]).create();
      final repoPath = p.join(d.sandbox, 'repo_safe');
      final git = await GitDir.init(repoPath, allowContent: true);
      await git.configureTestIdentity();
      await git.runCommand(['branch', '-M', 'main']);
      await git.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/myorg/safe-repo.git',
      ]);
      await git.runCommand(['add', '.']);
      await git.runCommand(['commit', '-m', 'init']);

      final wtPath = p.join(d.sandbox, '_safe-unlinked');
      await git.runCommand([
        'worktree',
        'add',
        '-b',
        'unpushed-branch',
        wtPath,
      ]);
      final wtGit = await GitDir.fromExisting(wtPath);
      await wtGit.configureTestIdentity();
      await File(p.join(wtPath, 'precious.txt'))
          .writeAsString('valuable unpushed work');
      await wtGit.runCommand(['add', '.']);
      await wtGit.runCommand(['commit', '-m', 'Precious unpushed commit']);

      final options = GhCleanOptions(localRoot: d.sandbox, apply: true);

      await runGhClean(
        options: options,
        processRunner: (exe, args, {workingDirectory}) {
          if (exe == 'gh') {
            final queryArg = args.firstWhere((a) => a.startsWith('query='));
            if (queryArg.contains('search(')) {
              // fetchLandedPrs returns 0 landed PRs
              return ProcessResult(
                1,
                0,
                jsonEncode({
                  'data': {
                    'search': {'nodes': <dynamic>[]},
                  },
                }),
                '',
              );
            } else {
              // findUnlinkedWorktrees query returns nodes: []
              return ProcessResult(
                1,
                0,
                jsonEncode({
                  'data': {
                    'q0': {
                      'pullRequests': {'nodes': <dynamic>[]},
                    },
                  },
                }),
                '',
              );
            }
          }
          return defaultSyncProcessRunner(
            exe,
            args,
            workingDirectory: workingDirectory,
          );
        },
      );

      // Verify worktree and its files are strictly preserved!
      check(Directory(wtPath).existsSync()).isTrue();
      check(File(p.join(wtPath, 'precious.txt')).existsSync()).isTrue();
      check(File(p.join(wtPath, 'precious.txt')).readAsStringSync())
          .equals('valuable unpushed work');
    });

    test(
      'does not report worktrees as unlinked if GraphQL query fails',
      () async {
        await d.dir('repo_err', [d.file('README.md', '# Err')]).create();
        final repoPath = p.join(d.sandbox, 'repo_err');
        final git = await GitDir.init(repoPath, allowContent: true);
        await git.configureTestIdentity();
        await git.runCommand(['branch', '-M', 'main']);
        await git.runCommand([
          'remote',
          'add',
          'origin',
          'https://github.com/myorg/err-repo.git',
        ]);
        await git.runCommand(['add', '.']);
        await git.runCommand(['commit', '-m', 'init']);

        final wtPath = p.join(d.sandbox, '_err-wt');
        await git.runCommand(['worktree', 'add', '-b', 'some-branch', wtPath]);

        final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

        final unlinked = await findUnlinkedWorktrees(
          localRepos,
          <String>{},
          processRunner: (exe, args, {workingDirectory}) {
            if (exe == 'gh') {
              return ProcessResult(
                1,
                1, // non-zero exit code!
                '',
                'network failure or rate limit exceeded',
              );
            }
            return defaultSyncProcessRunner(
              exe,
              args,
              workingDirectory: workingDirectory,
            );
          },
        );

        check(unlinked).isEmpty();
      },
    );
  });

  group('findCrossAuthorLandedPrs', () {
    test('identifies merged PRs authored by collaborators', () async {
      await d.dir('repo_cross_author', [
        d.file('README.md', '# Cross Author'),
      ]).create();
      final repoPath = p.join(d.sandbox, 'repo_cross_author');
      final git = await GitDir.init(repoPath, allowContent: true);
      await git.configureTestIdentity();
      await git.runCommand(['branch', '-M', 'main']);
      await git.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/googleapis/google-cloud-dart.git',
      ]);
      await git.runCommand(['add', '.']);
      await git.runCommand(['commit', '-m', 'init']);
      await git.runCommand(['branch', 'telemetry-header-fix']);

      final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

      final crossAuthorPrs = await findCrossAuthorLandedPrs(
        localRepos,
        <String>{},
        processRunner: (exe, args, {workingDirectory}) {
          if (exe == 'gh') {
            return ProcessResult(
              1,
              0,
              jsonEncode({
                'data': {
                  'q0': {
                    'nameWithOwner': 'googleapis/google-cloud-dart',
                    'url': 'https://github.com/googleapis/google-cloud-dart',
                    'pullRequests': {
                      'nodes': [
                        {
                          'number': 336,
                          'title':
                              'feat(storage): add gccl token for client '
                              'attribution',
                          'url':
                              'https://github.com/googleapis/google-cloud-dart'
                              '/pull/336',
                          'mergedAt': DateTime.now()
                              .toUtc()
                              .subtract(const Duration(days: 2))
                              .toIso8601String(),
                          'closedAt': DateTime.now()
                              .toUtc()
                              .subtract(const Duration(days: 2))
                              .toIso8601String(),
                          'headRefName': 'telemetry-header-fix',
                          'headRefOid':
                              '5acfde1d81cdea132151cba012dc95837f3b61aa',
                          'baseRefName': 'main',
                          'mergeCommit': {
                            'oid': '63578dfce15fce86fec0bbaa1758174b09bf3ecd',
                          },
                        },
                      ],
                    },
                  },
                },
              }),
              '',
            );
          }
          return defaultSyncProcessRunner(
            exe,
            args,
            workingDirectory: workingDirectory,
          );
        },
      );

      check(crossAuthorPrs.length).equals(1);
      final pr = crossAuthorPrs.first;
      check(pr.number).equals(336);
      check(pr.repository).equals('googleapis/google-cloud-dart');
      check(pr.headRefName).equals('telemetry-header-fix');
      check(pr.title)
          .equals('feat(storage): add gccl token for client attribution');
    });

    test('excludes branches already matched by user PRs', () async {
      await d.dir('repo_matched_branch', [
        d.file('README.md', '# Matched'),
      ]).create();
      final repoPath = p.join(d.sandbox, 'repo_matched_branch');
      final git = await GitDir.init(repoPath, allowContent: true);
      await git.configureTestIdentity();
      await git.runCommand(['branch', '-M', 'main']);
      await git.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/dart-lang/test.git',
      ]);
      await git.runCommand(['add', '.']);
      await git.runCommand(['commit', '-m', 'init']);
      await git.runCommand(['branch', 'already-matched']);

      final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

      final crossAuthorPrs = await findCrossAuthorLandedPrs(localRepos, {
        'already-matched',
      });

      check(crossAuthorPrs).isEmpty();
    });

    test('filters out PRs merged before lastNDays cutoff', () async {
      await d.dir('repo_cutoff', [d.file('README.md', '# Cutoff')]).create();
      final repoPath = p.join(d.sandbox, 'repo_cutoff');
      final git = await GitDir.init(repoPath, allowContent: true);
      await git.configureTestIdentity();
      await git.runCommand(['branch', '-M', 'main']);
      await git.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/myorg/old-repo.git',
      ]);
      await git.runCommand(['add', '.']);
      await git.runCommand(['commit', '-m', 'init']);
      await git.runCommand(['branch', 'old-branch']);

      final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

      final crossAuthorPrs = await findCrossAuthorLandedPrs(
        localRepos,
        <String>{},
        lastNDays: 14,
        processRunner: (exe, args, {workingDirectory}) {
          if (exe == 'gh') {
            return ProcessResult(
              1,
              0,
              jsonEncode({
                'data': {
                  'q0': {
                    'nameWithOwner': 'myorg/old-repo',
                    'url': 'https://github.com/myorg/old-repo',
                    'pullRequests': {
                      'nodes': [
                        {
                          'number': 100,
                          'title': 'old pr',
                          'url': 'https://github.com/myorg/old-repo/pull/100',
                          'mergedAt': DateTime.now()
                              .toUtc()
                              .subtract(const Duration(days: 30))
                              .toIso8601String(),
                          'headRefName': 'old-branch',
                          'headRefOid': 'abc1234',
                          'baseRefName': 'main',
                        },
                      ],
                    },
                  },
                },
              }),
              '',
            );
          }
          return defaultSyncProcessRunner(
            exe,
            args,
            workingDirectory: workingDirectory,
          );
        },
      );

      check(crossAuthorPrs).isEmpty();
    });

    test('extracts valid PRs even when gh exits with code 1 on partial batch '
        'errors', () async {
      await d.dir('repo_partial_err', [
        d.file('README.md', '# Partial Error'),
      ]).create();
      final repoPath = p.join(d.sandbox, 'repo_partial_err');
      final git = await GitDir.init(repoPath, allowContent: true);
      await git.configureTestIdentity();
      await git.runCommand(['branch', '-M', 'main']);
      await git.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/org/valid-repo.git',
      ]);
      await git.runCommand(['add', '.']);
      await git.runCommand(['commit', '-m', 'init']);
      await git.runCommand(['branch', 'collab-branch']);

      final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

      final crossAuthorPrs = await findCrossAuthorLandedPrs(
        localRepos,
        <String>{},
        processRunner: (exe, args, {workingDirectory}) {
          if (exe == 'gh') {
            return ProcessResult(
              1,
              1, // non-zero exit code due to partial GraphQL error
              jsonEncode({
                'data': {
                  'q0': {
                    'nameWithOwner': 'org/valid-repo',
                    'url': 'https://github.com/org/valid-repo',
                    'pullRequests': {
                      'nodes': [
                        {
                          'number': 42,
                          'title': 'collab pr',
                          'url': 'https://github.com/org/valid-repo/pull/42',
                          'mergedAt': DateTime.now()
                              .toUtc()
                              .subtract(const Duration(days: 1))
                              .toIso8601String(),
                          'headRefName': 'collab-branch',
                          'headRefOid': 'sha42',
                          'baseRefName': 'main',
                        },
                      ],
                    },
                  },
                },
                'errors': [
                  {'message': 'Could not resolve to a Repository'},
                ],
              }),
              'Could not resolve to a Repository',
            );
          }
          return defaultSyncProcessRunner(
            exe,
            args,
            workingDirectory: workingDirectory,
          );
        },
      );

      check(crossAuthorPrs.length).equals(1);
      check(crossAuthorPrs.first.number).equals(42);
    });

    test(
      'scoped alreadyMatchedRefs allows same branch name in another repo',
      () async {
        await d.dir('repo_scoped_a', [d.file('README.md', '# A')]).create();
        final repoAPath = p.join(d.sandbox, 'repo_scoped_a');
        final gitA = await GitDir.init(repoAPath, allowContent: true);
        await gitA.configureTestIdentity();
        await gitA.runCommand(['branch', '-M', 'main']);
        await gitA.runCommand([
          'remote',
          'add',
          'origin',
          'https://github.com/org/repo-a.git',
        ]);
        await gitA.runCommand(['add', '.']);
        await gitA.runCommand(['commit', '-m', 'init']);
        await gitA.runCommand(['branch', 'shared-feature']);

        await d.dir('repo_scoped_b', [d.file('README.md', '# B')]).create();
        final repoBPath = p.join(d.sandbox, 'repo_scoped_b');
        final gitB = await GitDir.init(repoBPath, allowContent: true);
        await gitB.configureTestIdentity();
        await gitB.runCommand(['branch', '-M', 'main']);
        await gitB.runCommand([
          'remote',
          'add',
          'origin',
          'https://github.com/org/repo-b.git',
        ]);
        await gitB.runCommand(['add', '.']);
        await gitB.runCommand(['commit', '-m', 'init']);
        await gitB.runCommand(['branch', 'shared-feature']);

        final localRepos = scanLocalGitRepositories(Directory(d.sandbox));

        // repo-a#shared-feature is matched, but repo-b#shared-feature
        // should NOT be excluded.
        final crossAuthorPrs = await findCrossAuthorLandedPrs(
          localRepos,
          {'org/repo-a#shared-feature'},
          processRunner: (exe, args, {workingDirectory}) {
            if (exe == 'gh') {
              return ProcessResult(
                1,
                0,
                jsonEncode({
                  'data': {
                    'q0': {
                      'nameWithOwner': 'org/repo-b',
                      'url': 'https://github.com/org/repo-b',
                      'pullRequests': {
                        'nodes': [
                          {
                            'number': 55,
                            'title': 'shared in b',
                            'url': 'https://github.com/org/repo-b/pull/55',
                            'mergedAt': DateTime.now()
                                .toUtc()
                                .subtract(const Duration(days: 1))
                                .toIso8601String(),
                            'headRefName': 'shared-feature',
                            'headRefOid': 'sha55',
                            'baseRefName': 'main',
                          },
                        ],
                      },
                    },
                  },
                }),
                '',
              );
            }
            return defaultSyncProcessRunner(
              exe,
              args,
              workingDirectory: workingDirectory,
            );
          },
        );

        check(crossAuthorPrs.length).equals(1);
        check(crossAuthorPrs.first.repository).equals('org/repo-b');
      },
    );
  });

  group('remote head branch cleanup', () {
    test('parseLandedPrNode parses headRef and headRepository permissions', () {
      final writePr = parseLandedPrNode({
        'number': 192710,
        'title': 'fix warning',
        'url': 'https://github.com/flutter/flutter/pull/192710',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
        },
        'headRefName': 'warn-dart-html-removal',
        'headRefOid': 'abc1234',
        'headRef': {'name': 'warn-dart-html-removal'},
        'headRepository': {
          'nameWithOwner': 'kevmoo/flutter',
          'viewerPermission': 'ADMIN',
        },
        'baseRefName': 'master',
      })!;

      check(writePr.headRefExists).isTrue();
      check(writePr.headRepository).equals('kevmoo/flutter');
      check(writePr.headRepoPermission).equals('ADMIN');
      check(writePr.canDeleteRemoteHeadBranch).isTrue();

      final readOnlyPr = parseLandedPrNode({
        'number': 192711,
        'title': 'collaborator pr',
        'url': 'https://github.com/flutter/flutter/pull/192711',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
        },
        'headRefName': 'other-branch',
        'headRefOid': 'def5678',
        'headRef': {'name': 'other-branch'},
        'headRepository': {
          'nameWithOwner': 'other/flutter',
          'viewerPermission': 'READ',
        },
        'baseRefName': 'master',
      })!;

      check(readOnlyPr.headRefExists).isTrue();
      check(readOnlyPr.canDeleteRemoteHeadBranch).isFalse();

      final deletedRefPr = parseLandedPrNode({
        'number': 192712,
        'title': 'deleted ref pr',
        'url': 'https://github.com/flutter/flutter/pull/192712',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
        },
        'headRefName': 'already-deleted',
        'headRefOid': '0123456',
        'headRef': null,
        'headRepository': {
          'nameWithOwner': 'kevmoo/flutter',
          'viewerPermission': 'ADMIN',
        },
        'baseRefName': 'master',
      })!;

      check(deletedRefPr.headRefExists).isFalse();
      check(deletedRefPr.canDeleteRemoteHeadBranch).isFalse();
    });

    test(
      'planCleanup and executeCleanup delete remote branch even without local '
      'repo',
      () {
        const pr = LandedPr(
          number: 324,
          title: 'release 0.5.5',
          url: 'https://github.com/firebase/firebase-admin-dart/pull/324',
          repository: 'firebase/firebase-admin-dart',
          repoUrl: 'https://github.com/firebase/firebase-admin-dart',
          headRefName: 'release-0.5.5',
          headRefOid: 'abc1234',
          baseRefName: 'main',
          headRefExists: true,
          headRepository: 'kevmoo/dart_firebase_admin',
          headRepoPermission: 'WRITE',
        );

        final planned = planCleanup(pr, null);
        check(planned).contains(
          'Delete remote branch `kevmoo/dart_firebase_admin:release-0.5.5`',
        );

        final skipped = planCleanup(pr, null, skipRemoteBranches: true);
        check(skipped).isEmpty();

        final calls = <String>[];
        final executed = executeCleanup(
          pr,
          null,
          processRunner: (exe, args, {workingDirectory}) {
            calls.add('$exe ${args.join(" ")}');
            return ProcessResult(1, 0, '', '');
          },
        );

        check(calls).contains(
          'gh api -X DELETE repos/kevmoo/dart_firebase_admin/git/refs/heads/release-0.5.5',
        );
        check(executed.length).equals(1);
        check(executed.first.success).isTrue();
        check(executed.first.description).equals(
          'Deleted remote branch `kevmoo/dart_firebase_admin:release-0.5.5`',
        );
      },
    );
  });

  group('worktree branch-mismatch & dry-run safety guards', () {
    test(
      'planCleanup and executeCleanup refuse to prune worktree switched to a '
      'different branch',
      () {
        const pr = LandedPr(
          number: 192953,
          title: 'Phase 3: precache_manifest.json',
          url: 'https://github.com/flutter/flutter/pull/192953',
          repository: 'flutter/flutter',
          repoUrl: 'https://github.com/flutter/flutter',
          headRefName: 'web-content-hash-phase-3',
          headRefOid: 'b2c1a67',
          baseRefName: 'master',
        );

        final localRepo = (
          repoName: 'flutter/flutter',
          repoNames: ['flutter/flutter'],
          repoPath: '/path/to/flutter',
          currentBranch: 'master',
          branches: [
            (
              name: 'web-content-hash-phase-3',
              sha: 'b2c1a67',
              upstream: null,
              upstreamTrack: null,
            ),
            (
              name: 'web-content-hash-phase-2-5',
              sha: '9999999',
              upstream: null,
              upstreamTrack: null,
            ),
            (
              name: 'master',
              sha: '000',
              upstream: 'origin/master',
              upstreamTrack: '',
            ),
          ],
          worktrees: [
            (
              path: '/path/to/_flutter-web-content-hash-phase-3',
              branch: 'web-content-hash-phase-2-5',
              sha: '9999999',
            ),
          ],
        );

        final planned = planCleanup(
          pr,
          localRepo,
          processRunner: (exe, args, {workingDirectory}) =>
              ProcessResult(0, 0, '', ''),
        );
        check(planned).contains(
          'Skip worktree at /path/to/_flutter-web-content-hash-phase-3 '
          '(checked out on `web-content-hash-phase-2-5`, '
          'expected `web-content-hash-phase-3`)',
        );
        check(planned)
            .contains('Delete local branch `web-content-hash-phase-3`');

        final calls = <String>[];
        final executed = executeCleanup(
          pr,
          localRepo,
          processRunner: (exe, args, {workingDirectory}) {
            calls.add('$exe ${args.join(" ")}');
            return ProcessResult(0, 0, '', '');
          },
        );

        check(calls).not((it) => it.any((c) => c.contains('worktree remove')));
        final wtAction = executed.firstWhere(
          (a) => a.description.contains('worktree'),
        );
        check(wtAction.success).isFalse();
        check(wtAction.error).isNotNull().contains(
          'Worktree branch mismatch '
          '(checked out on `web-content-hash-phase-2-5`, '
          'expected `web-content-hash-phase-3`).',
        );
      },
    );

    test('skips pruning worktree AND skips deleting branch when folder belongs '
        'to another branch (reverse mismatch)', () {
      const pr = LandedPr(
        number: 75,
        title: 'Experiment: Use BytesBuilder',
        url: 'https://github.com/kevmoo/codable.dart/pull/75',
        repository: 'kevmoo/codable.dart',
        repoUrl: 'https://github.com/kevmoo/codable.dart',
        headRefName: 'bytes-builder-copy',
        headRefOid: 'abc1234',
        baseRefName: 'main',
      );
      const localRepo = (
        repoName: 'kevmoo/codable.dart',
        repoNames: ['kevmoo/codable.dart'],
        repoPath: '/path/to/codable.dart',
        currentBranch: 'main',
        branches: [
          (
            name: 'bytes-builder-copy',
            sha: 'abc1234',
            upstream: null,
            upstreamTrack: null,
          ),
          (
            name: 'main',
            sha: 'abc1234',
            upstream: 'origin/main',
            upstreamTrack: '',
          ),
        ],
        worktrees: [
          (
            path: '/path/to/_codable.dart-rope-chunks',
            branch: 'bytes-builder-copy',
            sha: 'abc1234',
          ),
        ],
      );

      final planned = planCleanup(
        pr,
        localRepo,
        processRunner: (exe, args, {workingDirectory}) =>
            ProcessResult(0, 0, '', ''),
      );
      check(planned).contains(
        'Skip worktree at /path/to/_codable.dart-rope-chunks '
        '(folder matches `rope-chunks`, checked out on `bytes-builder-copy`)',
      );
      check(planned).contains(
        'Skip local branch `bytes-builder-copy` '
        '(checked out in worktree at /path/to/_codable.dart-rope-chunks)',
      );
      check(planned)
          .not((it) => it.contains('Delete local branch `bytes-builder-copy`'));

      final calls = <String>[];
      final executed = executeCleanup(
        pr,
        localRepo,
        processRunner: (exe, args, {workingDirectory}) {
          calls.add('$exe ${args.join(" ")}');
          return ProcessResult(0, 0, '', '');
        },
      );
      check(calls)
        ..not((it) => it.any((c) => c.contains('worktree remove')))
        ..not((it) => it.any((c) => c.contains('branch -D')));
      final branchAction = executed.firstWhere(
        (a) => a.description.contains('Delete local branch'),
      );
      check(branchAction.success).isFalse();
      check(branchAction.error).isNotNull().contains(
        'checked out in worktree at /path/to/_codable.dart-rope-chunks',
      );
    });

    test(
      'planCleanup appends git stash note and caches per repoPath',
      () async {
        await d.dir('stash-repo').create();
        final repoPath = p.join(d.sandbox, 'stash-repo');
        const pr = LandedPr(
          number: 79,
          title: 'Process isolation',
          url: 'https://github.com/kevmoo/codable.dart/pull/79',
          repository: 'kevmoo/codable.dart',
          repoUrl: 'https://github.com/kevmoo/codable.dart',
          headRefName: 'agent/kngtn-process-isolation',
          headRefOid: 'abc1234',
          baseRefName: 'main',
        );
        final localRepo = (
          repoName: 'kevmoo/codable.dart',
          repoNames: ['kevmoo/codable.dart'],
          repoPath: repoPath,
          currentBranch: 'main',
          branches: [
            (
              name: 'agent/kngtn-process-isolation',
              sha: 'abc1234',
              upstream: null,
              upstreamTrack: null,
            ),
            (
              name: 'main',
              sha: 'abc1234',
              upstream: 'origin/main',
              upstreamTrack: '',
            ),
          ],
          worktrees: <LocalWorktreeEntry>[],
        );

        var stashCalls = 0;
        final cache = <String, int>{};
        ProcessResult runner(
          String exe,
          List<String> args, {
          String? workingDirectory,
        }) {
          if (args.contains('stash') && args.contains('list')) {
            stashCalls++;
            return ProcessResult(
              0,
              0,
              'stash@{0}: WIP on main\nstash@{1}: WIP on feat\n',
              '',
            );
          }
          return ProcessResult(0, 0, '', '');
        }

        final planned1 = planCleanup(
          pr,
          localRepo,
          processRunner: runner,
          stashCountCache: cache,
        );
        final planned2 = planCleanup(
          pr,
          localRepo,
          processRunner: runner,
          stashCountCache: cache,
        );
        check(planned1).contains('Note: repository has 2 git stash(es)');
        check(planned2).contains('Note: repository has 2 git stash(es)');
        check(stashCalls).equals(1);
      },
    );
  });

  group('findClosedUnmergedPrs', () {
    test('identifies closed-unmerged PRs and formats Markdown/JSON report', () async {
      await d.dir('codable.dart', [d.dir('.git')]).create();
      final repoPath = p.join(d.sandbox, 'codable.dart');
      final localRepo = (
        repoName: 'kevmoo/codable.dart',
        repoNames: ['kevmoo/codable.dart'],
        repoPath: repoPath,
        currentBranch: 'main',
        branches: [
          (
            name: 'rope-chunks',
            sha: '9dd884beab',
            upstream: null,
            upstreamTrack: null,
          ),
          (
            name: 'main',
            sha: '000',
            upstream: 'origin/main',
            upstreamTrack: '',
          ),
        ],
        worktrees: [
          (
            path: '/path/to/_codable.dart-rope-chunks',
            branch: 'rope-chunks',
            sha: '9dd884beab',
          ),
        ],
      );

      final closedPrs = await findClosedUnmergedPrs(
        [localRepo],
        const {},
        processRunner: (exe, args, {workingDirectory}) {
          if (exe == 'gh') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'data': {
                  'q0': {
                    'nameWithOwner': 'kevmoo/codable.dart',
                    'openPrs': {'nodes': <Object>[]},
                    'mergedPrs': {
                      'nodes': [
                        {'number': 10},
                      ],
                    },
                    'closedPrs': {
                      'nodes': [
                        {
                          'number': 74,
                          'title': 'perf: rope chunks',
                          'url':
                              'https://github.com/kevmoo/codable.dart/pull/74',
                          'headRefOid': '9dd884beab',
                        },
                      ],
                    },
                  },
                },
              }),
              '',
            );
          }
          if (exe == 'git' && args.contains('rev-list')) {
            return ProcessResult(0, 0, '2\n', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      check(closedPrs.length).equals(1);
      final c = closedPrs.first;
      check(c.number).equals(74);
      check(c.branch).equals('rope-chunks');
      check(c.worktreePath).equals('/path/to/_codable.dart-rope-chunks');
      check(c.shaMatchesPrHead).isTrue();
      check(c.commitsAhead).equals(2);

      final md = formatMarkdownReport(
        const [],
        applied: false,
        closedUnmergedPrs: closedPrs,
      );
      check(md)
        ..contains('## Closed (Unmerged) Pull Requests')
        ..contains('[#74](https://github.com/kevmoo/codable.dart/pull/74)')
        ..contains('Local SHA matches closed PR HEAD (`9dd884b`');
    });
  });
}
