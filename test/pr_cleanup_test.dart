import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/gerrit_view/gerrit_queries.dart';
import 'package:kevmoo_scripts/src/pr_cleanup/collector.dart';
import 'package:kevmoo_scripts/src/pr_cleanup/models.dart';
import 'package:kevmoo_scripts/src/pr_cleanup/pr_cleanup_options.dart';
import 'package:kevmoo_scripts/src/pr_cleanup/report_formatter.dart';
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
        ..contains('## 📌 Locked Worktrees (FYI — Safe-Kept Local Work)')
        ..contains(
          '*Safe-kept via `git worktree lock --reason`. Review periodically '
          'and run `git worktree unlock <path>` when ready to prune.*',
        )
        ..contains('HTTP/1.1 raw socket benchmark spike')
        ..contains('2026-10-13<br>🟢&nbsp;1d&nbsp;ago')
        ..contains('⚠️ *(No --reason provided)*')
        ..contains('⚪ Unknown')
        ..contains('## ⚠️ Needs Triage')
        ..contains(
          '*Triage dangling worktrees by either deleting them or locking them '
          'for safekeeping with a descriptive project/context reason '
          '(`git -C <repo> worktree lock --reason "<project & why kept>" '
          '<worktree>`).*',
        )
        ..contains('Candidate landed handles: `#100, #200`')
        ..contains('tools_old')
        ..contains('Fix edge case in runner')
        ..contains('Worktree has 2 unpushed/unmerged commits');
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
      check((decoded['active'] as List).length).equals(1);
      check((decoded['readyToPrune'] as List).length).equals(1);
      check((decoded['lockedWorktrees'] as List).length).equals(1);
      check((decoded['needsTriage'] as List).length).equals(0);
      check((decoded['candidateLandedIds'] as List).cast<int>())
          .deepEquals([41]);
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

      check(sweep.active.length).equals(1);
      check(sweep.active.single.number).equals(1614);
      check(sweep.active.single.worktreePath).equals(activeWt.path);

      check(sweep.lockedWorktrees.length).equals(2);
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
}

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
