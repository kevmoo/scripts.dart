import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/gerrit_view.dart';
import 'package:kevmoo_scripts/src/gerrit_view/gerrit_queries.dart';
import 'package:kevmoo_scripts/src/gerrit_view/models.dart';
import 'package:kevmoo_scripts/src/gh_clean/models.dart';
import 'package:kevmoo_scripts/src/local_repo_scanner.dart';
import 'package:kevmoo_scripts/src/pr_cleanup.dart';
import 'package:kevmoo_scripts/src/pr_cleanup/cleanup_executor.dart';
import 'package:kevmoo_scripts/src/pr_cleanup/collector.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PrCleanupOptions', () {
    test('default options', () {
      final parser = PrCleanupOptions.createArgParser();
      final results = parser.parse([]);
      final options = PrCleanupOptions.parse(results);

      check(options.user).equals('@me');
      check(options.repo).isNull();
      check(options.limit).equals(50);
      check(options.lastNDays).equals(14);
      check(options.skipGerrit).isFalse();
      check(options.apply).isFalse();
      check(options.excludeWorktrees).isEmpty();
      check(options.markdown).isTrue();
      check(options.json).isFalse();
      check(parser.usage).contains(
        'Execute pruning of ready-to-prune worktrees and branches across '
        'GitHub and Gerrit.',
      );
    });

    test('custom flags and options', () {
      final parser = PrCleanupOptions.createArgParser();
      final results = parser.parse([
        '--user',
        'alice',
        '-R',
        'dart-lang/tools',
        '-R',
        'flutter/flutter',
        '--limit',
        '75',
        '--last-n-days',
        '30',
        '--local-root',
        '/custom/root',
        '--dart-sdk',
        '/custom/sdk',
        '--skip-gerrit',
        '--apply',
        '--exclude-worktree',
        '/custom/root/_demo-hold',
        '--exclude-worktree',
        ' /custom/root/_demo-second ',
        '--json',
      ]);
      final options = PrCleanupOptions.parse(results);

      check(options.user).equals('alice');
      check(options.repo).equals('dart-lang/tools,flutter/flutter');
      check(options.limit).equals(75);
      check(options.lastNDays).equals(30);
      check(options.localRoot).equals('/custom/root');
      check(options.dartSdkPath).equals('/custom/sdk');
      check(options.skipGerrit).isTrue();
      check(options.apply).isTrue();
      check(options.excludeWorktrees)
          .deepEquals(['/custom/root/_demo-hold', '/custom/root/_demo-second']);
      check(options.json).isTrue();
    });

    test('throws UsageException on invalid limit', () {
      final parser = PrCleanupOptions.createArgParser();
      final results = parser.parse(['--limit', 'notanumber']);
      check(() => PrCleanupOptions.parse(results)).throws<UsageException>();
    });

    test('throws UsageException on negative or over-100 limit', () {
      final parser = PrCleanupOptions.createArgParser();
      final zeroResults = parser.parse(['--limit', '0']);
      check(() => PrCleanupOptions.parse(zeroResults)).throws<UsageException>();

      final overResults = parser.parse(['--limit', '101']);
      check(() => PrCleanupOptions.parse(overResults)).throws<UsageException>();
    });

    test('throws UsageException on invalid lastNDays', () {
      final parser = PrCleanupOptions.createArgParser();
      final results = parser.parse(['--last-n-days', 'invalid']);
      check(() => PrCleanupOptions.parse(results)).throws<UsageException>();
    });

    test('lastNDays 0 sets null (unbounded)', () {
      final parser = PrCleanupOptions.createArgParser();
      final results = parser.parse(['--last-n-days', '0']);
      final options = PrCleanupOptions.parse(results);
      check(options.lastNDays).isNull();
    });
  });

  group('formatMarkdownReport', () {
    test('renders empty sweep cleanly without Bucket A/B/C indirection', () {
      final result = PrSweepResult(
        active: const [],
        readyToPrune: const [],
        lockedWorktrees: const [],
        needsTriage: const [],
        candidateLandedIds: const [],
        timestamp: DateTime(2026, 10, 14),
      );

      final report = formatMarkdownReport(result);
      check(report)
        ..contains('# 🧹 PR & Worktree Cleanup Sweep Overview')
        ..contains(
          '| **Ready to Prune** | 0 | 0 | Landed PRs & merged Gerrit CLs |',
        )
        ..contains(
          '| **Active / In-Flight** | 0 | 0 | Open PRs & active Gerrit CLs |',
        )
        ..contains(
          '| **Locked Worktrees (FYI)** | 0 | 0 | '
          'Safe-kept local worktrees (`git worktree lock`) |',
        )
        ..contains(
          '| **Needs Triage** | 0 | 0 | '
          'Unlocked unlinked worktrees & unmerged commits |',
        )
        ..contains('## ✅ Ready to Prune')
        ..contains('## 🚫 Active / Hands-Off')
        ..contains('Zero worktrees or branches ready for immediate pruning.')
        ..contains('Zero open PRs or active CLs found.')
        ..not((it) => it.contains('Bucket A'))
        ..not((it) => it.contains('Bucket B'))
        ..not((it) => it.contains('Bucket C'))
        ..not((it) => it.contains('## 📌 Locked Worktrees'))
        ..not((it) => it.contains('## ⚠️ Needs Triage'));
    });

    test('renders populated sweep with all sections and locked worktrees', () {
      final result = PrSweepResult(
        active: const [
          ActiveItem(
            source: 'github',
            number: 123,
            title: 'Fix edge case in runner',
            repository: 'dart-lang/tools',
            url: 'https://github.com/dart-lang/tools/pull/123',
            branch: 'feat/fix-edge-case',
            ciBadge: '🟢 PASS',
            reviewBadge: '🟡 AWAITING',
            author: 'kevmoo',
            isDraft: false,
            worktreePath: '/home/user/github/tools_worktree',
          ),
          ActiveItem(
            source: 'gerrit',
            number: 456,
            title: '[analyzer] improve lint parsing',
            repository: 'dart-sdk',
            url: 'https://dart-review.googlesource.com/c/sdk/+/456',
            branch: 'cl-456',
            ciBadge: '🟢 PASS',
            reviewBadge: '🟢 LGTM',
            author: 'kevmoo',
            isDraft: false,
          ),
        ],
        readyToPrune: const [
          PrunableItem(
            source: 'github',
            prOrClNumber: 100,
            repository: 'dart-lang/tools',
            branch: 'feat/old-branch',
            worktreePath: '/home/user/github/tools_old',
            description: 'Landed PR #100',
          ),
          PrunableItem(
            source: 'gerrit',
            prOrClNumber: 200,
            repository: 'dart-sdk',
            branch: 'cl-200',
            description: 'Merged CL 200',
          ),
        ],
        lockedWorktrees: [
          LockedWorktreeItem(
            repository: 'kevmoo/shelf',
            worktreePath: '/home/user/github/_shelf-raw-socket-proto',
            branch: 'feat/raw-socket',
            lockReason: 'HTTP/1.1 raw socket benchmark spike',
            commitsAhead: 2,
            lastCommitDate: '2026-10-13',
            updatedAt: DateTime(2026, 10, 13),
          ),
          const LockedWorktreeItem(
            repository: 'kevmoo/other',
            worktreePath: '/home/user/github/_other-no-reason',
            branch: 'wip-spike',
            commitsAhead: 0,
          ),
        ],
        needsTriage: const [
          TriageItem(
            source: 'github',
            prOrClNumber: 999,
            repository: 'dart-lang/tools',
            branch: 'unmerged-branch',
            worktreePath: '/home/user/github/tools_unmerged',
            reason: 'Worktree has 2 unpushed/unmerged commits',
          ),
        ],
        candidateLandedIds: const [100, 200],
        timestamp: DateTime(2026, 10, 14, 12),
      );

      final report = formatMarkdownReport(result);
      check(report)
        ..contains('# 🧹 PR & Worktree Cleanup Sweep Overview')
        ..contains('## ✅ Ready to Prune')
        ..contains('## 🚫 Active / Hands-Off')
        ..contains('## ⚠️ Needs Triage')
        ..contains(
          '*Triage dangling worktrees by either deleting them or locking them '
          'for safekeeping with a descriptive project/context reason '
          '(`git -C <repo> worktree lock --reason "<project & why kept>" '
          '<worktree>`).*',
        )
        ..contains('## 📌 Locked Worktrees (FYI — Safe-Kept Local Work)')
        ..contains(
          '*Safe-kept via `git worktree lock --reason`. Review periodically '
          'and run `git worktree unlock <path>` when ready to prune.*',
        )
        ..contains('HTTP/1.1 raw socket benchmark spike')
        ..contains('2026-10-13<br>🟢&nbsp;1d&nbsp;ago')
        ..contains('⚠️ *(No --reason provided)*')
        ..contains('⚪ Unknown')
        ..contains('Candidate landed handles: `#100, #200`')
        ..contains('tools_old')
        ..contains('Fix edge case in runner')
        ..contains('Worktree has 2 unpushed/unmerged commits');

      final readyIdx = report.indexOf('## ✅ Ready to Prune');
      final activeIdx = report.indexOf('## 🚫 Active / Hands-Off');
      final triageIdx = report.indexOf('## ⚠️ Needs Triage');
      final lockedIdx = report.indexOf(
        '## 📌 Locked Worktrees (FYI — Safe-Kept Local Work)',
      );
      check(readyIdx).isLessThan(activeIdx);
      check(activeIdx).isLessThan(triageIdx);
      check(triageIdx).isLessThan(lockedIdx);
    });

    test('renders applied header when applied is true', () {
      final result = PrSweepResult(
        active: const [],
        readyToPrune: const [],
        lockedWorktrees: const [],
        needsTriage: const [],
        candidateLandedIds: const [],
        timestamp: DateTime(2026, 10, 14),
      );

      final report = formatMarkdownReport(result, applied: true);
      check(report)
          .contains('# 🧹 PR & Worktree Cleanup Sweep [🚀 Applied Pruning]');
    });
  });

  group('formatJsonReport', () {
    test('renders valid JSON with descriptive keys', () {
      final result = PrSweepResult(
        active: const [
          ActiveItem(
            source: 'github',
            number: 42,
            title: 'Test PR',
            repository: 'kevmoo/test',
            url: 'https://github.com/kevmoo/test/pull/42',
            branch: 'test-branch',
            ciBadge: '🟢 PASS',
            reviewBadge: '⚪ NONE',
            author: 'kevmoo',
            isDraft: false,
          ),
        ],
        readyToPrune: const [
          PrunableItem(
            source: 'github',
            prOrClNumber: 41,
            repository: 'kevmoo/test',
            branch: 'feat-41',
            description: 'Landed PR #41',
          ),
        ],
        lockedWorktrees: [
          LockedWorktreeItem(
            repository: 'kevmoo/test',
            worktreePath: '/tmp/_test-locked',
            branch: 'locked-branch',
            lockReason: 'Hold for v2',
            commitsAhead: 1,
            lastCommitSubject: 'WIP v2',
            lastCommitDate: '2026-10-12',
            updatedAt: DateTime.utc(2026, 10, 12),
          ),
        ],
        needsTriage: const [],
        candidateLandedIds: const [41],
        timestamp: DateTime(2026, 10, 14),
      );

      final jsonStr = formatJsonReport(result, applied: true);
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      check(decoded['applied']).equals(true);
      check(decoded.containsKey('applyResult')).isFalse();
      check((decoded['active'] as List).length).equals(1);
      check((decoded['readyToPrune'] as List).length).equals(1);
      check((decoded['lockedWorktrees'] as List).length).equals(1);
      check((decoded['needsTriage'] as List).length).equals(0);
      check((decoded['candidateLandedIds'] as List).cast<int>())
          .deepEquals([41]);

      final withApplyStr = formatJsonReport(
        result,
        applied: true,
        applyResult: const PrCleanupApplyResult(
          prunedWorktrees: 2,
          deletedBranches: 3,
          deletedRemoteBranches: 1,
          skippedWorktrees: ['/tmp/_demo-busy'],
          errors: ['failed branch delete'],
        ),
      );
      final withApply = jsonDecode(withApplyStr) as Map<String, dynamic>;
      final applyMap = withApply['applyResult'] as Map<String, dynamic>;
      check(applyMap['prunedWorktrees']).equals(2);
      check(applyMap['deletedBranches']).equals(3);
      check(applyMap['deletedRemoteBranches']).equals(1);
      check((applyMap['skippedWorktrees'] as List).cast<String>())
          .deepEquals(['/tmp/_demo-busy']);
      check((applyMap['errors'] as List).cast<String>())
          .deepEquals(['failed branch delete']);
    });

    test('includes createdAt, updatedAt, and activity timestamps in Markdown '
        'and JSON', () {
      final now = DateTime.utc(2026, 10, 15, 20);
      final created = DateTime.utc(2026, 10, 3, 12);
      final updated = DateTime.utc(2026, 10, 15, 18);
      final authorAct = DateTime.utc(2026, 10, 15, 17);
      final reviewerAct = DateTime.utc(2026, 10, 15, 18);

      final result = PrSweepResult(
        active: [
          ActiveItem(
            source: 'github',
            number: 42,
            title: 'Test PR with dates',
            repository: 'kevmoo/test',
            url: 'https://github.com/kevmoo/test/pull/42',
            branch: 'test-branch',
            ciBadge: '🟢 Passing',
            reviewBadge: '⏳ In Review Queue',
            author: 'kevmoo',
            isDraft: false,
            createdAt: created,
            updatedAt: updated,
            lastAuthorActivityAt: authorAct,
            lastReviewerActivityAt: reviewerAct,
          ),
        ],
        readyToPrune: const [],
        lockedWorktrees: const [],
        needsTriage: const [],
        candidateLandedIds: const [],
        timestamp: now,
      );

      final md = formatMarkdownReport(result);
      check(md)
        ..contains('Opened / Touched')
        ..contains(
          'Opened:&nbsp;2026-10-03<br>Touched:&nbsp;🟢&nbsp;2h&nbsp;ago',
        );

      final decoded =
          jsonDecode(formatJsonReport(result)) as Map<String, dynamic>;
      final item = (decoded['active'] as List).single as Map<String, dynamic>;
      check(item['createdAt']).equals(created.toIso8601String());
      check(item['updatedAt']).equals(updated.toIso8601String());
      check(item['lastAuthorActivityAt']).equals(authorAct.toIso8601String());
      check(item['lastReviewerActivityAt'])
          .equals(reviewerAct.toIso8601String());
    });
  });

  group('collectPrSweep worktree partitioning', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('pr_cleanup_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('routes locked worktrees to lockedWorktrees and prevents active PR '
        'worktrees from leaking into needsTriage', () async {
      final repoDir = Directory('${tempRoot.path}/demo')..createSync();
      Directory('${repoDir.path}/.git').createSync();

      final activeWt = Directory('${tempRoot.path}/_demo-active-pr')
        ..createSync();
      File('${activeWt.path}/.git').writeAsStringSync('gitdir: ...');

      final lockedReasonWt = Directory('${tempRoot.path}/_demo-locked-spike')
        ..createSync();
      File('${lockedReasonWt.path}/.git').writeAsStringSync('gitdir: ...');

      final lockedNoReasonWt = Directory(
        '${tempRoot.path}/_demo-locked-noreason',
      )..createSync();
      File('${lockedNoReasonWt.path}/.git').writeAsStringSync('gitdir: ...');

      final unlockedWt = Directory('${tempRoot.path}/_demo-unlocked-dangling')
        ..createSync();
      File('${unlockedWt.path}/.git').writeAsStringSync('gitdir: ...');

      final sweep = await collectPrSweep(
        options: PrCleanupOptions(localRoot: tempRoot.path, skipGerrit: true),
        syncProcessRunner: (exe, args, {workingDirectory}) => _mockSyncRunner(
          exe,
          args,
          workingDirectory: workingDirectory,
          repoPath: repoDir.path,
          activeWtPath: activeWt.path,
          lockedReasonWtPath: lockedReasonWt.path,
          lockedNoReasonWtPath: lockedNoReasonWt.path,
          unlockedWtPath: unlockedWt.path,
        ),
        asyncProcessRunner: (exe, args, {workingDirectory}) async =>
            _mockAsyncOpenPrsRunner(),
      );

      check(sweep.active.map((a) => a.number)).deepEquals([1620, 1614]);
      check(sweep.active.last.worktreePath).equals(activeWt.path);

      check(sweep.lockedWorktrees.length).equals(2);
      check(sweep.lockedWorktrees.first.worktreePath)
          .equals(lockedNoReasonWt.path);
      check(sweep.lockedWorktrees.last.worktreePath)
          .equals(lockedReasonWt.path);
      final withReason = sweep.lockedWorktrees.firstWhere(
        (w) => w.worktreePath == lockedReasonWt.path,
      );
      check(withReason.lockReason).equals('Project X: layout spike');
      check(withReason.commitsAhead).equals(2);
      check(withReason.updatedAt).equals(DateTime(2026, 10, 18));

      final withoutReason = sweep.lockedWorktrees.firstWhere(
        (w) => w.worktreePath == lockedNoReasonWt.path,
      );
      check(withoutReason.lockReason).isNull();
      check(withoutReason.commitsAhead).equals(0);
      check(withoutReason.updatedAt).isNotNull();

      check(sweep.needsTriage.length).equals(1);
      check(sweep.needsTriage.single.worktreePath).equals(unlockedWt.path);

      final md = formatMarkdownReport(sweep);
      check(md)
        ..contains('## 📌 Locked Worktrees (FYI — Safe-Kept Local Work)')
        ..contains('Project X: layout spike')
        ..contains('⚠️ *(No --reason provided)*')
        ..contains('_demo-unlocked-dangling');
    });

    test('surfaces unanswered reviewer comments and thread counts across '
        'GitHub PRs and Gerrit CLs', () async {
      final sweep = await collectPrSweep(
        options: PrCleanupOptions(localRoot: tempRoot.path),
        syncProcessRunner: (exe, args, {workingDirectory}) => ProcessResult(
          0,
          0,
          exe == 'gh'
              ? jsonEncode({
                  'data': {
                    'search': {'nodes': <Object?>[]},
                  },
                })
              : '',
          '',
        ),
        asyncProcessRunner: (exe, args, {workingDirectory}) async =>
            _mockUntriagedGithubPrsRunner(),
        gerritAnalyzer: () async => _mockGerritAnalysisResult(tempRoot.path),
      );

      final byNumber = {for (final item in sweep.active) item.number: item};

      check(byNumber[2633]!.reviewBadge)
          .equals('❌ Unresolved Comments (2, Approved)');
      check(byNumber[2633]!.unresolvedReviewerThreads).equals(2);
      check(byNumber[2633]!.unresolvedAuthorThreads).equals(0);

      check(byNumber[78]!.reviewBadge)
          .equals('❌ Unresolved Comments (4, Approved)');

      check(byNumber[2638]!.reviewBadge).equals('❌ Unresolved Comments (5)');
      check(byNumber[2638]!.unresolvedReviewerThreads).equals(5);

      check(byNumber[2640]!.reviewBadge)
          .equals('🔴 Changes Requested (1 unresolved)');

      check(byNumber[18855]!.reviewBadge).equals('🔄 Re-request Review');
      check(byNumber[18855]!.unresolvedReviewerThreads).equals(0);
      check(byNumber[18855]!.unresolvedAuthorThreads).equals(1);

      check(byNumber[517]!.reviewBadge)
          .equals('⚪ Work in progress (2 unresolved)');

      check(byNumber[567604]!.reviewBadge).equals('❌ Unresolved Comments (1)');
      check(byNumber[567604]!.unresolvedReviewerThreads).equals(1);

      check(byNumber[567582]!.reviewBadge)
          .equals('❌ Unresolved Comments (1, Approved)');

      check(byNumber[563381]!.reviewBadge)
          .equals('🔴 Changes Requested (2 unresolved)');

      check(byNumber[507265]!.reviewBadge).equals('⏳ Awaiting Review');
      check(byNumber[507265]!.unresolvedReviewerThreads).equals(0);
      check(byNumber[507265]!.unresolvedAuthorThreads).equals(1);

      final decoded =
          jsonDecode(formatJsonReport(sweep)) as Map<String, dynamic>;
      final activeJson = (decoded['active'] as List)
          .cast<Map<String, dynamic>>();
      final gerritJson = activeJson.firstWhere((i) => i['number'] == 567604);
      check(gerritJson['unresolvedReviewerThreads']).equals(1);
      check(gerritJson['unresolvedAuthorThreads']).equals(0);
    });
  });

  group('parseGerritTimestamp', () {
    test('parses Gerrit UTC timestamp strings to DateTime', () {
      final parsed = parseGerritTimestamp('2026-10-08 02:30:11.000000000');
      check(parsed).isNotNull();
      check(parsed!.toUtc()).equals(DateTime.utc(2026, 10, 8, 2, 30, 11));
      check(parseGerritTimestamp(null)).isNull();
      check(parseGerritTimestamp('')).isNull();
    });
  });

  group('executeReadyToPrune and runPrCleanup --apply', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('pr_cleanup_apply_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('skips excluded GitHub and Gerrit worktrees while pruning sibling '
        'items in the same repository', () async {
      final repoPath = '${tempRoot.path}/demo';
      final wtHold = '${tempRoot.path}/_demo-feat-hold';
      final wtPrune = '${tempRoot.path}/_demo-feat-prune';
      final gerritSdk = Directory('${tempRoot.path}/dart-sdk')..createSync();
      final wtGerritHold = '${gerritSdk.path}/core/cl-99/sdk';
      final wtGerritPrune = '${gerritSdk.path}/core/cl-100/sdk';

      final localRepo = <LocalRepoInfo>[
        (
          repoName: 'kevmoo/demo',
          repoNames: ['kevmoo/demo'],
          repoPath: repoPath,
          currentBranch: 'main',
          branches: [
            (
              name: 'main',
              sha: '0000',
              upstream: 'origin/main',
              upstreamTrack: '',
            ),
            (
              name: 'feat-hold',
              sha: '1111',
              upstream: 'origin/feat-hold',
              upstreamTrack: '',
            ),
            (
              name: 'feat-prune',
              sha: '2222',
              upstream: 'origin/feat-prune',
              upstreamTrack: '',
            ),
          ],
          worktrees: [
            (
              path: repoPath,
              branch: 'main',
              sha: '0000',
              isLocked: false,
              lockReason: null,
            ),
            (
              path: wtHold,
              branch: 'feat-hold',
              sha: '1111',
              isLocked: false,
              lockReason: null,
            ),
            (
              path: wtPrune,
              branch: 'feat-prune',
              sha: '2222',
              isLocked: false,
              lockReason: null,
            ),
          ],
        ),
      ];

      final commands = <String>[];
      final applyResult = await executeReadyToPrune(
        items: [
          PrunableItem(
            source: 'github',
            repository: 'kevmoo/demo',
            branch: 'feat-hold',
            worktreePath: wtHold,
            remoteBranch: 'kevmoo/demo:feat-hold',
            prOrClNumber: 10,
            description: 'Landed PR #10',
            landedPr: _buildTestLandedPr(
              number: 10,
              branch: 'feat-hold',
              sha: '1111',
            ),
          ),
          PrunableItem(
            source: 'github',
            repository: 'kevmoo/demo',
            branch: 'feat-prune',
            worktreePath: wtPrune,
            remoteBranch: 'kevmoo/demo:feat-prune',
            prOrClNumber: 11,
            description: 'Landed PR #11',
            landedPr: _buildTestLandedPr(
              number: 11,
              branch: 'feat-prune',
              sha: '2222',
            ),
          ),
          PrunableItem(
            source: 'gerrit',
            repository: 'dart-sdk',
            branch: 'cl-99',
            worktreePath: wtGerritHold,
            prOrClNumber: 99,
            description: 'CL 99 (merged)',
          ),
          PrunableItem(
            source: 'gerrit',
            repository: 'dart-sdk',
            branch: 'cl-100',
            worktreePath: wtGerritPrune,
            prOrClNumber: 100,
            description: 'CL 100 (merged)',
          ),
        ],
        localRepos: localRepo,
        excludedWorktrees: ['$wtHold/', wtGerritHold],
        dartSdkPath: gerritSdk.path,
        syncProcessRunner: (exe, args, {workingDirectory}) {
          commands.add('$exe ${args.join(' ')}');
          return ProcessResult(0, 0, '', '');
        },
      );

      check(applyResult.skippedWorktrees).deepEquals([wtHold, wtGerritHold]);
      check(applyResult.prunedWorktrees).equals(2);
      check(applyResult.deletedBranches).equals(2);
      check(applyResult.deletedRemoteBranches).equals(1);
      check(applyResult.errors).isEmpty();

      check(commands).any((it) => it.contains('worktree remove $wtPrune'));
      check(commands).any((it) => it.contains('branch -D feat-prune'));
      check(commands).any(
        (it) =>
            it.contains('DELETE repos/kevmoo/demo/git/refs/heads/feat-prune'),
      );
      check(commands)
          .any((it) => it.contains('worktree remove $wtGerritPrune'));
      check(commands).any((it) => it.contains('branch -D cl-100'));

      for (final cmd in commands) {
        check(cmd)
          ..not((it) => it.contains(wtHold))
          ..not((it) => it.contains('feat-hold'))
          ..not((it) => it.contains(wtGerritHold))
          ..not((it) => it.contains('cl-99'));
      }
    });

    test('runPrCleanup writes applyResult in JSON cache when apply is true and '
        'omits it when apply is false', () async {
      final cacheFile = File('${tempRoot.path}/sweep_cache.json');
      ProcessResult emptyGhSync(
        String exe,
        List<String> args, {
        String? workingDirectory,
      }) => ProcessResult(
        0,
        0,
        exe == 'gh'
            ? jsonEncode({
                'data': {
                  'search': {'nodes': <Object?>[]},
                },
              })
            : '',
        '',
      );
      Future<ProcessResult> emptyGhAsync(
        String exe,
        List<String> args, {
        String? workingDirectory,
      }) async => emptyGhSync(exe, args, workingDirectory: workingDirectory);

      await runPrCleanup(
        options: PrCleanupOptions(
          localRoot: tempRoot.path,
          skipGerrit: true,
          json: true,
        ),
        syncProcessRunner: emptyGhSync,
        asyncProcessRunner: emptyGhAsync,
        jsonCachePath: cacheFile.path,
      );
      final dryRunJson =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      check(dryRunJson['applied']).equals(false);
      check(dryRunJson.containsKey('applyResult')).isFalse();

      await runPrCleanup(
        options: PrCleanupOptions(
          localRoot: tempRoot.path,
          skipGerrit: true,
          apply: true,
          json: true,
        ),
        syncProcessRunner: emptyGhSync,
        asyncProcessRunner: emptyGhAsync,
        jsonCachePath: cacheFile.path,
      );
      final applyJson =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      check(applyJson['applied']).equals(true);
      final applyResult = applyJson['applyResult'] as Map<String, dynamic>;
      check(applyResult['prunedWorktrees']).equals(0);
      check(applyResult['deletedBranches']).equals(0);
      check(applyResult['deletedRemoteBranches']).equals(0);
      check(applyResult['skippedWorktrees'] as List).isEmpty();
      check(applyResult['errors'] as List).isEmpty();
    });
  });
}

LandedPr _buildTestLandedPr({
  required int number,
  required String branch,
  required String sha,
}) => LandedPr(
  number: number,
  title: 'PR $number',
  url: 'https://github.com/kevmoo/demo/pull/$number',
  repository: 'kevmoo/demo',
  repoUrl: 'https://github.com/kevmoo/demo',
  headRefName: branch,
  headRefOid: sha,
  baseRefName: 'main',
  headRefExists: true,
  headRepository: 'kevmoo/demo',
  headRepoPermission: 'ADMIN',
);

ProcessResult _mockAsyncOpenPrsRunner() {
  final payload = {
    'data': {
      'search': {
        'nodes': [
          {
            'number': 1614,
            'title': 'WIP: JS interop migration',
            'url': 'https://github.com/kevmoo/demo/pull/1614',
            'author': {'login': 'kevmoo'},
            'isDraft': true,
            'state': 'OPEN',
            'reviewDecision': null,
            'reviewRequests': {'nodes': <Object?>[]},
            'reviews': {'nodes': <Object?>[]},
            'reviewThreads': {'totalCount': 0, 'nodes': <Object?>[]},
            'comments': {'nodes': <Object?>[]},
            'commits': {'nodes': <Object?>[]},
            'mergeable': 'MERGEABLE',
            'mergeStateStatus': 'DRAFT',
            'mergeQueueEntry': null,
            'headRefName': 'js-interop',
            'headRefOid': 'aaaa1111',
            'baseRefName': 'main',
            'repository': {
              'nameWithOwner': 'kevmoo/demo',
              'url': 'https://github.com/kevmoo/demo',
              'isArchived': false,
            },
            'createdAt': '2026-10-10T00:00:00Z',
            'updatedAt': '2026-10-19T00:00:00Z',
          },
          {
            'number': 1620,
            'title': 'Fix newer issue',
            'url': 'https://github.com/kevmoo/demo/pull/1620',
            'author': {'login': 'kevmoo'},
            'isDraft': false,
            'state': 'OPEN',
            'reviewDecision': null,
            'reviewRequests': {'nodes': <Object?>[]},
            'reviews': {'nodes': <Object?>[]},
            'reviewThreads': {'totalCount': 0, 'nodes': <Object?>[]},
            'comments': {'nodes': <Object?>[]},
            'commits': {'nodes': <Object?>[]},
            'mergeable': 'MERGEABLE',
            'mergeStateStatus': 'CLEAN',
            'mergeQueueEntry': null,
            'headRefName': 'fix-newer',
            'headRefOid': 'ffff9999',
            'baseRefName': 'main',
            'repository': {
              'nameWithOwner': 'kevmoo/demo',
              'url': 'https://github.com/kevmoo/demo',
              'isArchived': false,
            },
            'createdAt': '2026-10-12T00:00:00Z',
            'updatedAt': '2026-10-20T01:00:00Z',
          },
        ],
      },
    },
  };
  return ProcessResult(0, 0, jsonEncode(payload), '');
}

ProcessResult _mockSyncRunner(
  String exe,
  List<String> args, {
  required String? workingDirectory,
  required String repoPath,
  required String activeWtPath,
  required String lockedReasonWtPath,
  required String lockedNoReasonWtPath,
  required String unlockedWtPath,
}) {
  if (exe == 'gh') {
    final emptyData = {
      'data': {
        'search': {'nodes': <Object?>[]},
        'q0': {
          'nameWithOwner': 'kevmoo/demo',
          'url': 'https://github.com/kevmoo/demo',
          'pullRequests': {'nodes': <Object?>[]},
          'openPrs': {'nodes': <Object?>[]},
          'mergedPrs': {'nodes': <Object?>[]},
          'closedPrs': {'nodes': <Object?>[]},
        },
        'q1': {
          'nameWithOwner': 'kevmoo/demo',
          'url': 'https://github.com/kevmoo/demo',
          'pullRequests': {'nodes': <Object?>[]},
          'openPrs': {'nodes': <Object?>[]},
          'mergedPrs': {'nodes': <Object?>[]},
          'closedPrs': {'nodes': <Object?>[]},
        },
        'q2': {
          'nameWithOwner': 'kevmoo/demo',
          'url': 'https://github.com/kevmoo/demo',
          'pullRequests': {'nodes': <Object?>[]},
          'openPrs': {'nodes': <Object?>[]},
          'mergedPrs': {'nodes': <Object?>[]},
          'closedPrs': {'nodes': <Object?>[]},
        },
        'q3': {
          'nameWithOwner': 'kevmoo/demo',
          'url': 'https://github.com/kevmoo/demo',
          'pullRequests': {'nodes': <Object?>[]},
          'openPrs': {'nodes': <Object?>[]},
          'mergedPrs': {'nodes': <Object?>[]},
          'closedPrs': {'nodes': <Object?>[]},
        },
      },
    };
    return ProcessResult(0, 0, jsonEncode(emptyData), '');
  }

  if (args.contains('remote') && args.contains('-v')) {
    return ProcessResult(
      0,
      0,
      'origin\thttps://github.com/kevmoo/demo.git (fetch)\n',
      '',
    );
  }
  if (args.contains('for-each-ref')) {
    return ProcessResult(0, 0, 'main\t0000base\torigin/main\t\n', '');
  }
  if (args.contains('worktree') && args.contains('--porcelain')) {
    return ProcessResult(
      0,
      0,
      'worktree $repoPath\n'
          'HEAD 0000base\n'
          'branch refs/heads/main\n\n'
          'worktree $activeWtPath\n'
          'HEAD bbbb2222\n'
          'branch refs/heads/js-interop\n\n'
          'worktree $lockedReasonWtPath\n'
          'HEAD cccc3333\n'
          'branch refs/heads/locked-spike\n'
          'locked Project X: layout spike\n\n'
          'worktree $lockedNoReasonWtPath\n'
          'HEAD dddd4444\n'
          'branch refs/heads/locked-noreason\n'
          'locked\n\n'
          'worktree $unlockedWtPath\n'
          'HEAD eeee5555\n'
          'branch refs/heads/unlocked-dangling\n',
      '',
    );
  }
  if (args.contains('rev-list') && args.contains('--count')) {
    final count = workingDirectory == lockedNoReasonWtPath
        ? '0'
        : workingDirectory == lockedReasonWtPath
        ? '2'
        : '1';
    return ProcessResult(0, 0, '$count\n', '');
  }
  if (args.contains('log') && args.contains('-1')) {
    if (workingDirectory == lockedNoReasonWtPath) {
      return ProcessResult(0, 1, '', '');
    }
    return ProcessResult(0, 0, '2026-10-18|WIP commit\n', '');
  }
  return ProcessResult(0, 0, 'main\n', '');
}

Map<String, dynamic> _mockPrNode({
  required int number,
  required String? reviewDecision,
  bool isDraft = false,
  List<String> requestedReviewers = const [],
  List<Map<String, dynamic>> reviews = const [],
  List<Map<String, dynamic>> threadNodes = const [],
  String? committedDate,
}) => {
  'number': number,
  'title': 'PR $number',
  'url': 'https://github.com/dart-lang/tools/pull/$number',
  'author': {'login': 'kevmoo'},
  'isDraft': isDraft,
  'state': 'OPEN',
  'reviewDecision': reviewDecision,
  'reviewRequests': {
    'nodes': [
      for (final r in requestedReviewers)
        {
          'requestedReviewer': {'login': r},
        },
    ],
  },
  'reviews': {'nodes': reviews},
  'reviewThreads': {'totalCount': threadNodes.length, 'nodes': threadNodes},
  'comments': {'nodes': <Object?>[]},
  'commits': {
    'nodes': [
      if (committedDate != null)
        {
          'commit': {
            'committedDate': committedDate,
            'statusCheckRollup': {'state': 'SUCCESS'},
          },
        },
    ],
  },
  'mergeable': 'MERGEABLE',
  'mergeStateStatus': 'CLEAN',
  'headRefName': 'branch-$number',
  'headRefOid': 'sha-$number',
  'baseRefName': 'main',
  'repository': {
    'nameWithOwner': 'dart-lang/tools',
    'url': 'https://github.com/dart-lang/tools',
    'isArchived': false,
  },
  'createdAt': '2026-10-20T00:00:00Z',
  'updatedAt': '2026-10-23T00:00:00Z',
};

Map<String, dynamic> _mockThread(String login, {bool isResolved = false}) => {
  'isResolved': isResolved,
  'comments': {
    'nodes': [
      {
        'author': {'__typename': 'User', 'login': login},
      },
    ],
  },
};

ProcessResult _mockUntriagedGithubPrsRunner() {
  final payload = {
    'data': {
      'search': {
        'nodes': [
          _mockPrNode(
            number: 2633,
            reviewDecision: 'APPROVED',
            threadNodes: [_mockThread('natebosch'), _mockThread('natebosch')],
          ),
          _mockPrNode(
            number: 2638,
            reviewDecision: 'REVIEW_REQUIRED',
            requestedReviewers: ['jakemac53'],
            threadNodes: List.filled(5, _mockThread('jakemac53')),
          ),
          _mockPrNode(
            number: 2640,
            reviewDecision: 'CHANGES_REQUESTED',
            threadNodes: [_mockThread('jakemac53')],
          ),
          _mockPrNode(
            number: 18855,
            reviewDecision: 'REVIEW_REQUIRED',
            requestedReviewers: ['Lyokone'],
            reviews: [
              {
                'author': {'login': 'SelaseKay'},
                'submittedAt': '2026-10-21T01:00:00Z',
                'state': 'COMMENTED',
              },
            ],
            threadNodes: [_mockThread('kevmoo')],
            committedDate: '2026-10-22T01:00:00Z',
          ),
          _mockPrNode(
            number: 517,
            reviewDecision: null,
            isDraft: true,
            threadNodes: [_mockThread('alice'), _mockThread('alice')],
          ),
          _mockPrNode(
            number: 78,
            reviewDecision: '',
            reviews: [
              {
                'author': {'login': 'davidmorgan'},
                'submittedAt': '2026-10-22T12:00:00Z',
                'state': 'APPROVED',
              },
            ],
            threadNodes: List.filled(4, _mockThread('davidmorgan')),
          ),
        ],
      },
    },
  };
  return ProcessResult(0, 0, jsonEncode(payload), '');
}

RemoteCL _mockGerritCl({
  required int number,
  List<String> reviewers = const ['reviewer@google.com'],
  List<String> crVotes = const [],
  int unresolvedReviewerLeaves = 0,
  int unresolvedAuthorLeaves = 0,
}) => (
  number: number,
  changeId: 'I$number',
  subject: 'CL $number',
  status: 'NEW',
  currentRevision: 'rev-$number',
  currentRevisionNumber: 1,
  lastAuthorTouch: '2026-10-23T00:00:00Z',
  createdAt: DateTime.utc(2026, 10, 20),
  updatedAt: DateTime.utc(2026, 10, 23),
  reviewers: reviewers,
  crVotes: crVotes,
  cqStatus: 'PASS',
  threads: (
    totalThreads: unresolvedReviewerLeaves + unresolvedAuthorLeaves,
    unresolvedReviewerLeaves: unresolvedReviewerLeaves,
    unresolvedAuthorLeaves: unresolvedAuthorLeaves,
  ),
  nextAction: '',
  submittable: true,
  unsatisfiedRequirements: const [],
);

GerritAnalysisResult _mockGerritAnalysisResult(String rootPath) {
  final cls = <int, RemoteCL>{
    567604: _mockGerritCl(number: 567604, unresolvedReviewerLeaves: 1),
    567582: _mockGerritCl(
      number: 567582,
      crVotes: ['reviewer:+1'],
      unresolvedReviewerLeaves: 1,
    ),
    563381: _mockGerritCl(
      number: 563381,
      crVotes: ['reviewer:-1'],
      unresolvedReviewerLeaves: 2,
    ),
    507265: _mockGerritCl(number: 507265, unresolvedAuthorLeaves: 1),
  };
  return (
    actualRepoRoot: rootPath,
    defaultBranch: 'main',
    currentBranch: 'main',
    gerritHost: 'dart-review.googlesource.com',
    gerritProject: 'sdk',
    gerritRemote: 'origin',
    remoteCLs: cls,
    branchDetails: const {},
    alignedBranches: const {},
    closedClBranches: const {},
    conflatedBranches: const {},
    mismatchedChangeIdBranches: const {},
    remoteOnlyCLs: cls,
    worktreeBranches: const {},
  );
}
