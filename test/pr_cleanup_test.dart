import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/gerrit_view/gerrit_queries.dart';
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
    test('renders empty sweep cleanly', () {
      final result = PrSweepResult(
        bucketA: const [],
        bucketB: const [],
        bucketC: const [],
        candidateLandedIds: const [],
        timestamp: DateTime(2026, 10, 14),
      );

      final report = formatMarkdownReport(result);
      check(report)
        ..contains('# 🧹 PR & Worktree Cleanup Sweep Overview')
        ..contains('Zero worktrees or branches ready for immediate pruning.')
        ..contains('Zero open PRs or active CLs found.');
    });

    test('renders populated sweep with all buckets', () {
      final result = PrSweepResult(
        bucketA: const [
          BucketAItem(
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
          BucketAItem(
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
        bucketB: const [
          BucketBItem(
            source: 'github',
            prOrClNumber: 100,
            repository: 'dart-lang/tools',
            branch: 'feat/old-branch',
            worktreePath: '/home/user/github/tools_old',
            description: 'Landed PR #100',
          ),
          BucketBItem(
            source: 'gerrit',
            prOrClNumber: 200,
            repository: 'dart-sdk',
            branch: 'cl-200',
            description: 'Merged CL 200',
          ),
        ],
        bucketC: const [
          BucketCItem(
            source: 'github',
            prOrClNumber: 999,
            repository: 'dart-lang/tools',
            branch: 'unmerged-branch',
            worktreePath: '/home/user/github/tools_unmerged',
            reason: 'Worktree has 2 unpushed/unmerged commits',
          ),
        ],
        candidateLandedIds: const [100, 200],
        timestamp: DateTime(2026, 10, 14),
      );

      final report = formatMarkdownReport(result);
      check(report)
        ..contains('# 🧹 PR & Worktree Cleanup Sweep Overview')
        ..contains('## ✅ Bucket B — Safe to Prune Immediately')
        ..contains('## 🚫 Bucket A — Active / Hands-Off')
        ..contains('## ⚠️ Bucket C — Requires Explicit Confirmation')
        ..contains('Candidate landed handles: `#100, #200`')
        ..contains('tools_old')
        ..contains('Fix edge case in runner')
        ..contains('Worktree has 2 unpushed/unmerged commits');
    });

    test('renders applied header when applied is true', () {
      final result = PrSweepResult(
        bucketA: const [],
        bucketB: const [],
        bucketC: const [],
        candidateLandedIds: const [],
        timestamp: DateTime(2026, 10, 14),
      );

      final report = formatMarkdownReport(result, applied: true);
      check(report)
          .contains('# 🧹 PR & Worktree Cleanup Sweep [🚀 Applied Pruning]');
    });
  });

  group('formatJsonReport', () {
    test('renders valid JSON with applied flag and buckets', () {
      final result = PrSweepResult(
        bucketA: const [
          BucketAItem(
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
        bucketB: const [
          BucketBItem(
            source: 'github',
            prOrClNumber: 41,
            repository: 'kevmoo/test',
            branch: 'feat-41',
            description: 'Landed PR #41',
          ),
        ],
        bucketC: const [],
        candidateLandedIds: const [41],
        timestamp: DateTime(2026, 10, 14),
      );

      final jsonStr = formatJsonReport(result, applied: true);
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      check(decoded['applied']).equals(true);
      check((decoded['bucketA'] as List).length).equals(1);
      check((decoded['bucketB'] as List).length).equals(1);
      check((decoded['bucketC'] as List).length).equals(0);
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
        bucketA: [
          BucketAItem(
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
        bucketB: const [],
        bucketC: const [],
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
      final item = (decoded['bucketA'] as List).single as Map<String, dynamic>;
      check(item['createdAt']).equals(created.toIso8601String());
      check(item['updatedAt']).equals(updated.toIso8601String());
      check(item['lastAuthorActivityAt']).equals(authorAct.toIso8601String());
      check(item['lastReviewerActivityAt'])
          .equals(reviewerAct.toIso8601String());
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
