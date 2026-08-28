import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/gh_view.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('formatTimeAgo', () {
    final baseTime = DateTime.parse('2026-08-13T12:00:00Z');

    test('returns just now for future or zero difference', () {
      check(formatTimeAgo(baseTime, currentTime: baseTime)).equals('just now');
      check(
        formatTimeAgo(
          baseTime.add(const Duration(minutes: 5)),
          currentTime: baseTime,
        ),
      ).equals('just now');
    });

    test('returns minutes for < 1 hour', () {
      final t1 = baseTime.subtract(const Duration(minutes: 1));
      check(formatTimeAgo(t1, currentTime: baseTime)).equals('just now');

      final t25 = baseTime.subtract(const Duration(minutes: 25));
      check(formatTimeAgo(t25, currentTime: baseTime)).equals('25m ago');

      final t59 = baseTime.subtract(const Duration(minutes: 59));
      check(formatTimeAgo(t59, currentTime: baseTime)).equals('59m ago');
    });

    test('returns hours for 1 to 24 hours', () {
      final t1h = baseTime.subtract(const Duration(hours: 1));
      check(formatTimeAgo(t1h, currentTime: baseTime)).equals('1h ago');

      final t14h = baseTime.subtract(const Duration(hours: 14));
      check(formatTimeAgo(t14h, currentTime: baseTime)).equals('14h ago');

      final t24h = baseTime.subtract(const Duration(hours: 24));
      check(formatTimeAgo(t24h, currentTime: baseTime)).equals('24h ago');
    });

    test('returns days for > 24 hours', () {
      final t2d = baseTime.subtract(const Duration(days: 2));
      check(formatTimeAgo(t2d, currentTime: baseTime)).equals('2d ago');

      final t45d = baseTime.subtract(const Duration(days: 45));
      check(formatTimeAgo(t45d, currentTime: baseTime)).equals('45d ago');
    });

    test(
      'getTouchedColor and formatTouchedMarkdown classify colors correctly',
      () {
        final t6d = baseTime.subtract(const Duration(days: 6));
        check(getTouchedColor(t6d, currentTime: baseTime))
            .equals(TouchedColor.green);
        check(formatTouchedMarkdown(t6d, currentTime: baseTime))
            .equals('🟢 6d ago');

        final t7d = baseTime.subtract(const Duration(days: 7));
        check(getTouchedColor(t7d, currentTime: baseTime))
            .equals(TouchedColor.yellow);
        check(formatTouchedMarkdown(t7d, currentTime: baseTime))
            .equals('🟡 7d ago');

        final t14d = baseTime.subtract(const Duration(days: 14));
        check(getTouchedColor(t14d, currentTime: baseTime))
            .equals(TouchedColor.orange);
        check(formatTouchedMarkdown(t14d, currentTime: baseTime))
            .equals('🟠 14d ago');

        final t28d = baseTime.subtract(const Duration(days: 28));
        check(getTouchedColor(t28d, currentTime: baseTime))
            .equals(TouchedColor.orange);
        check(formatTouchedMarkdown(t28d, currentTime: baseTime))
            .equals('🟠 28d ago');

        final t29d = baseTime.subtract(const Duration(days: 29));
        check(getTouchedColor(t29d, currentTime: baseTime))
            .equals(TouchedColor.red);
        check(formatTouchedMarkdown(t29d, currentTime: baseTime))
            .equals('🔴 29d ago');
      },
    );
  });

  group('normalizeRepoName', () {
    test('handles git@github.com URLs', () {
      check(normalizeRepoName('git@github.com:dart-lang/build.git'))
          .equals('dart-lang/build');
      check(normalizeRepoName('git@github.com:dart-lang/build'))
          .equals('dart-lang/build');
    });

    test('handles https://github.com URLs', () {
      check(normalizeRepoName('https://github.com/flutter/flutter.git'))
          .equals('flutter/flutter');
      check(normalizeRepoName('https://github.com/flutter/flutter'))
          .equals('flutter/flutter');
    });

    test('returns null for non-github URLs', () {
      check(normalizeRepoName('https://gitlab.com/foo/bar')).isNull();
    });
  });

  group('parsePrNode', () {
    test('parses full GraphQL node correctly', () {
      final node = {
        'number': 5078,
        'title': 'Deduplicate compiler process execution',
        'url': 'https://github.com/dart-lang/build/pull/5078',
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'REVIEW_REQUIRED',
        'mergeable': 'MERGEABLE',
        'headRefName': 'refactor/deslop-dedup',
        'headRefOid': '9e5af6f1272b5581625bd6f2fbd1750e2af54757',
        'baseRefName': 'master',
        'updatedAt': '2026-08-13T17:36:16Z',
        'repository': {
          'nameWithOwner': 'dart-lang/build',
          'url': 'https://github.com/dart-lang/build',
        },
        'commits': {
          'nodes': [
            {
              'commit': {
                'statusCheckRollup': {'state': 'FAILURE'},
              },
            },
          ],
        },
      };

      final pr = parsePrNode(node);
      check(pr).isNotNull();
      check(pr!.number).equals(5078);
      check(pr.title).equals('Deduplicate compiler process execution');
      check(pr.repository).equals('dart-lang/build');
      check(pr.reviewDecision).equals('REVIEW_REQUIRED');
      check(pr.ciStatus).equals('FAILURE');
      check(pr.mergeable).equals('MERGEABLE');
      check(pr.isDraft).isFalse();
    });

    test('detects tree-status failure for flutter/flutter as TREE_BROKEN', () {
      final node = {
        'number': 191084,
        'title': "add 'c: tfw4' label to Wasm issue template",
        'url': 'https://github.com/flutter/flutter/pull/191084',
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'APPROVED',
        'mergeable': 'MERGEABLE',
        'headRefName': 'wasm-issue-template-tfw4-label',
        'headRefOid': '0e7cb91a2305410d73b2ec0f3c8ba01346249851',
        'baseRefName': 'master',
        'updatedAt': '2026-08-13T19:49:15Z',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
          'isArchived': false,
        },
        'commits': {
          'nodes': [
            {
              'commit': {
                'statusCheckRollup': {
                  'state': 'FAILURE',
                  'contexts': {
                    'nodes': [
                      {
                        '__typename': 'StatusContext',
                        'context': 'tree-status',
                        'state': 'FAILURE',
                      },
                      {
                        '__typename': 'CheckRun',
                        'name': 'Tree_analyze',
                        'conclusion': 'SUCCESS',
                        'status': 'COMPLETED',
                      },
                    ],
                  },
                },
              },
            },
          ],
        },
      };

      final pr = parsePrNode(node);
      check(pr).isNotNull();
      check(pr!.repository).equals('flutter/flutter');
      check(pr.ciStatus).equals('TREE_BROKEN');
    });

    test('keeps FAILURE for flutter/flutter when real test fails', () {
      final node = {
        'number': 191084,
        'title': "add 'c: tfw4' label to Wasm issue template",
        'url': 'https://github.com/flutter/flutter/pull/191084',
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'APPROVED',
        'mergeable': 'MERGEABLE',
        'headRefName': 'wasm-issue-template-tfw4-label',
        'headRefOid': '0e7cb91a2305410d73b2ec0f3c8ba01346249851',
        'baseRefName': 'master',
        'updatedAt': '2026-08-13T19:49:15Z',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
          'isArchived': false,
        },
        'commits': {
          'nodes': [
            {
              'commit': {
                'statusCheckRollup': {
                  'state': 'FAILURE',
                  'contexts': {
                    'nodes': [
                      {
                        '__typename': 'StatusContext',
                        'context': 'tree-status',
                        'state': 'FAILURE',
                      },
                      {
                        '__typename': 'CheckRun',
                        'name':
                            'Linux_android '
                            'android_semantics_integration_test',
                        'conclusion': 'FAILURE',
                        'status': 'COMPLETED',
                      },
                    ],
                  },
                },
              },
            },
          ],
        },
      };

      final pr = parsePrNode(node);
      check(pr).isNotNull();
      check(pr!.repository).equals('flutter/flutter');
      check(pr.ciStatus).equals('FAILURE');
    });
  });

  group('categorizePullRequests', () {
    final now = DateTime.parse('2026-08-13T20:00:00Z');

    GhPr makePr({
      required int number,
      bool isDraft = false,
      bool isRepoArchived = false,
      bool isInMergeQueue = false,
      String reviewDecision = 'NONE',
      List<String> requestedReviewers = const [],
      int totalReviewThreads = 0,
      int unresolvedReviewThreads = 0,
      String ciStatus = 'SUCCESS',
      String mergeable = 'MERGEABLE',
    }) => (
      number: number,
      title: 'PR $number',
      url: 'https://github.com/dart-lang/build/pull/$number',
      isDraft: isDraft,
      state: 'OPEN',
      reviewDecision: reviewDecision,
      requestedReviewers: requestedReviewers,
      totalReviewThreads: totalReviewThreads,
      unresolvedReviewThreads: unresolvedReviewThreads,
      mergeable: mergeable,
      isInMergeQueue: isInMergeQueue,
      headRefName: 'branch-$number',
      headRefOid: 'sha-$number',
      baseRefName: 'main',
      repository: 'dart-lang/build',
      repoUrl: 'https://github.com/dart-lang/build',
      isRepoArchived: isRepoArchived,
      ciStatus: ciStatus,
      updatedAt: now,
      localStatus: null,
      context: null,
    );

    test(
      'categorizes readyToMerge, actionNeeded, inReview, drafts, archived',
      () {
        final prs = [
          makePr(number: 1, reviewDecision: 'APPROVED', isInMergeQueue: true),
          makePr(number: 2, reviewDecision: 'CHANGES_REQUESTED'),
          makePr(
            number: 3,
            reviewDecision: 'REVIEW_REQUIRED',
            ciStatus: 'FAILURE',
          ),
          makePr(
            number: 4,
            reviewDecision: 'REVIEW_REQUIRED',
            mergeable: 'CONFLICTING',
          ),
          makePr(number: 5, reviewDecision: 'REVIEW_REQUIRED'),
          makePr(number: 6, isDraft: true),
          makePr(number: 7, isRepoArchived: true),
          makePr(
            number: 8,
            reviewDecision: 'CHANGES_REQUESTED',
            requestedReviewers: ['harryterkelsen'],
          ),
        ];

        final cat = categorizePullRequests(prs);
        check(cat.readyToMerge.map((p) => p.number)).deepEquals([1]);
        check(cat.actionNeeded.map((p) => p.number)).deepEquals([2, 3, 4]);
        check(cat.inReview.map((p) => p.number)).deepEquals([5, 8]);
        check(cat.drafts.map((p) => p.number)).deepEquals([6]);
        check(cat.archived.map((p) => p.number)).deepEquals([7]);
      },
    );
  });

  group('renderJsonOutput', () {
    test('serializes structured summary and items', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = (
        number: 100,
        title: 'Feature XYZ',
        url: 'https://github.com/org/repo/pull/100',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: 'APPROVED',
        requestedReviewers: ['alice'],
        totalReviewThreads: 5,
        unresolvedReviewThreads: 0,
        mergeable: 'MERGEABLE',
        isInMergeQueue: false,
        headRefName: 'feat-xyz',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'main',
        repository: 'org/repo',
        repoUrl: 'https://github.com/org/repo',
        isRepoArchived: false,
        ciStatus: 'SUCCESS',
        updatedAt: now.subtract(const Duration(hours: 2)),
        localStatus: (
          repoPath: '/path/to/repo',
          branchName: 'feat-xyz',
          shortSha: 'abcdef1',
          isDirty: false,
          isHeadMatching: true,
          isWorktree: false,
          displayStatus: '🟢 Synced',
        ),
        context: null,
      );

      final jsonStr = renderJsonOutput([pr], currentTime: now);
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      final summary = decoded['summary'] as Map<String, dynamic>;
      check(summary['total']).equals(1);
      check(summary['readyToMerge']).equals(1);
      final readyList = (decoded['readyToMerge'] as List)
          .cast<Map<String, dynamic>>();
      check(readyList).length.equals(1);
      check(readyList[0]['number']).equals(100);
      check(readyList[0]['touched']).equals('2h ago');
      check((readyList[0]['requestedReviewers'] as List).cast<String>())
          .deepEquals(['alice']);
      check(readyList[0]['totalReviewThreads']).equals(5);
      check(readyList[0]['unresolvedReviewThreads']).equals(0);
      check(readyList[0]['areAllReviewThreadsResolved']).equals(true);
      check(readyList[0]['isRepoArchived']).equals(false);
      check(readyList[0]['isInMergeQueue']).equals(false);
      final localMap = readyList[0]['local'] as Map<String, dynamic>;
      check(localMap['status']).equals('🟢 Synced');
    });
  });

  group('renderMarkdownReport', () {
    test('renders markdown tables with sections', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = (
        number: 100,
        title: 'Feature XYZ',
        url: 'https://github.com/org/repo/pull/100',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: 'APPROVED',
        requestedReviewers: <String>[],
        totalReviewThreads: 0,
        unresolvedReviewThreads: 0,
        mergeable: 'MERGEABLE',
        isInMergeQueue: true,
        headRefName: 'feat-xyz',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'main',
        repository: 'org/repo',
        repoUrl: 'https://github.com/org/repo',
        isRepoArchived: false,
        ciStatus: 'SUCCESS',
        updatedAt: now.subtract(const Duration(hours: 2)),
        localStatus: (
          repoPath: '/path/to/repo',
          branchName: 'feat-xyz',
          shortSha: 'abcdef1',
          isDirty: false,
          isHeadMatching: true,
          isWorktree: false,
          displayStatus: '🟢 Synced',
        ),
        context: null,
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('# 🐙 GitHub Pull Request Overview Dashboard');
      check(md).contains('## 🚀 1. Ready to Merge');
      check(md).contains('[#100](https://github.com/org/repo/pull/100)');
      check(md).contains('`[🔀 Merge Queue]`');
      check(md).contains('🟢 Synced');
    });

    test(
      'renders Re-review Needed when changes requested but threads resolved',
      () {
        final now = DateTime.parse('2026-08-13T20:00:00Z');
        final pr = (
          number: 190891,
          title: 'refactor wasm dry-run result handling',
          url: 'https://github.com/flutter/flutter/pull/190891',
          isDraft: false,
          state: 'OPEN',
          reviewDecision: 'CHANGES_REQUESTED',
          requestedReviewers: <String>[],
          totalReviewThreads: 12,
          unresolvedReviewThreads: 0,
          mergeable: 'MERGEABLE',
          isInMergeQueue: false,
          headRefName: 'dry-run-refactor',
          headRefOid: 'abcdef1234567890',
          baseRefName: 'master',
          repository: 'flutter/flutter',
          repoUrl: 'https://github.com/flutter/flutter',
          isRepoArchived: false,
          ciStatus: 'TREE_BROKEN',
          updatedAt: now.subtract(const Duration(hours: 19)),
          localStatus: null,
          context: null,
        );

        final md = renderMarkdownReport([pr], currentTime: now);
        check(md).contains('🔄 **Re-review Needed** (threads resolved)');
        check(md).contains('🔴&nbsp;Changes&nbsp;Requested&nbsp;(Resolved)');
      },
    );

    test('renders Re-review Requested when review requests pending', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = (
        number: 190891,
        title: 'refactor wasm dry-run result handling',
        url: 'https://github.com/flutter/flutter/pull/190891',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: 'CHANGES_REQUESTED',
        requestedReviewers: ['harryterkelsen'],
        totalReviewThreads: 12,
        unresolvedReviewThreads: 0,
        mergeable: 'MERGEABLE',
        isInMergeQueue: false,
        headRefName: 'dry-run-refactor',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'master',
        repository: 'flutter/flutter',
        repoUrl: 'https://github.com/flutter/flutter',
        isRepoArchived: false,
        ciStatus: 'TREE_BROKEN',
        updatedAt: now.subtract(const Duration(hours: 19)),
        localStatus: null,
        context: null,
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('🟡 **Re-review Requested** (@harryterkelsen)');
    });

    test('renders Ping Reviewer when review required and threads resolved', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = (
        number: 2598,
        title: 'Move to Safari drive',
        url: 'https://github.com/dart-lang/test/pull/2598',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: 'REVIEW_REQUIRED',
        requestedReviewers: ['natebosch'],
        totalReviewThreads: 3,
        unresolvedReviewThreads: 0,
        mergeable: 'MERGEABLE',
        isInMergeQueue: false,
        headRefName: 'safari_sily',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'master',
        repository: 'dart-lang/test',
        repoUrl: 'https://github.com/dart-lang/test',
        isRepoArchived: false,
        ciStatus: 'SUCCESS',
        updatedAt: now.subtract(const Duration(days: 1)),
        localStatus: null,
        context: null,
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('🔔 **Ping Reviewer** (@natebosch)');
    });
  });

  group('runGhView with mocked processRunner', () {
    test('renders report with mock GraphQL response', () async {
      final mockData = {
        'data': {
          'search': {
            'issueCount': 1,
            'nodes': [
              {
                'number': 191084,
                'title': "add 'c: tfw4' label to Wasm issue template",
                'url': 'https://github.com/flutter/flutter/pull/191084',
                'isDraft': false,
                'state': 'OPEN',
                'reviewDecision': 'APPROVED',
                'mergeable': 'MERGEABLE',
                'headRefName': 'wasm-issue-template-tfw4-label',
                'headRefOid': '0e7cb91a2305410d73b2ec0f3c8ba01346249851',
                'baseRefName': 'master',
                'updatedAt': '2026-08-13T19:49:15Z',
                'repository': {
                  'nameWithOwner': 'flutter/flutter',
                  'url': 'https://github.com/flutter/flutter',
                },
                'commits': {
                  'nodes': [
                    {
                      'commit': {
                        'statusCheckRollup': {'state': 'SUCCESS'},
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      };

      ProcessResult mockRunner(
        String exe,
        List<String> args, {
        String? workingDirectory,
      }) {
        if (exe == 'gh' && args.contains('graphql')) {
          return ProcessResult(1234, 0, jsonEncode(mockData), '');
        }
        return ProcessResult(1234, 0, '', '');
      }

      final prints = <String>[];
      await wrappedForTesting(() async {
        final printsList = await _capturePrints(() async {
          await runGhView(
            options: const GhViewOptions(checkLocal: false),
            processRunner: (exe, args, {workingDirectory}) async =>
                mockRunner(exe, args, workingDirectory: workingDirectory),
            now: DateTime.parse('2026-08-13T20:00:00Z'),
          );
        });
        prints.addAll(printsList);
      });

      final output = prints.join('\n');
      check(output).contains('GITHUB PULL REQUEST OVERVIEW');
      check(output).contains('READY TO MERGE');
      check(output).contains('flutter/flutter#191084');
      check(output).contains('Approved');
      check(output).contains('CI: Passing');
    });

    test('filters PRs by lastNDays correctly', () async {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final mockData = {
        'data': {
          'search': {
            'issueCount': 2,
            'nodes': [
              {
                'number': 101,
                'title': 'Recent PR (2d old)',
                'url': 'https://github.com/dart-lang/build/pull/101',
                'isDraft': false,
                'state': 'OPEN',
                'reviewDecision': 'APPROVED',
                'mergeable': 'MERGEABLE',
                'headRefName': 'recent-branch',
                'headRefOid': 'sha101',
                'baseRefName': 'master',
                'updatedAt': '2026-08-11T20:00:00Z',
                'repository': {
                  'nameWithOwner': 'dart-lang/build',
                  'url': 'https://github.com/dart-lang/build',
                },
                'commits': {
                  'nodes': [
                    {
                      'commit': {
                        'statusCheckRollup': {'state': 'SUCCESS'},
                      },
                    },
                  ],
                },
              },
              {
                'number': 102,
                'title': 'Old PR (10d old)',
                'url': 'https://github.com/dart-lang/build/pull/102',
                'isDraft': false,
                'state': 'OPEN',
                'reviewDecision': 'APPROVED',
                'mergeable': 'MERGEABLE',
                'headRefName': 'old-branch',
                'headRefOid': 'sha102',
                'baseRefName': 'master',
                'updatedAt': '2026-08-03T20:00:00Z',
                'repository': {
                  'nameWithOwner': 'dart-lang/build',
                  'url': 'https://github.com/dart-lang/build',
                },
                'commits': {
                  'nodes': [
                    {
                      'commit': {
                        'statusCheckRollup': {'state': 'SUCCESS'},
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      };

      ProcessResult mockRunner(
        String exe,
        List<String> args, {
        String? workingDirectory,
      }) {
        if (exe == 'gh' && args.contains('graphql')) {
          return ProcessResult(1234, 0, jsonEncode(mockData), '');
        }
        return ProcessResult(1234, 0, '', '');
      }

      final prints = <String>[];
      await wrappedForTesting(() async {
        final printsList = await _capturePrints(() async {
          await runGhView(
            options: const GhViewOptions(checkLocal: false, lastNDays: 7),
            processRunner: (exe, args, {workingDirectory}) async =>
                mockRunner(exe, args, workingDirectory: workingDirectory),
            now: now,
          );
        });
        prints.addAll(printsList);
      });

      final output = prints.join('\n');
      check(output).contains('dart-lang/build#101');
      check(output).not((c) => c.contains('dart-lang/build#102'));
    });

    test('throws GhViewException when gh command fails', () async {
      ProcessResult mockFailingRunner(
        String exe,
        List<String> args, {
        String? workingDirectory,
      }) => ProcessResult(1234, 1, '', 'auth error');

      await check(
        runGhView(
          options: const GhViewOptions(checkLocal: false),
          processRunner: (exe, args, {workingDirectory}) async =>
              mockFailingRunner(exe, args, workingDirectory: workingDirectory),
        ),
      ).throws<GhViewException>();
    });
  });

  group('GhViewOptions.createArgParser', () {
    test('parses --last-n-days and aliases', () {
      final parser = GhViewOptions.createArgParser();
      check(parser.parse(['--last-n-days', '7'])['last-n-days']).equals('7');
      check(parser.parse(['-d', '14'])['last-n-days']).equals('14');
      check(parser.parse(['--last-days', '3'])['last-n-days']).equals('3');
      check(parser.parse(['--days', '5'])['last-n-days']).equals('5');
    });

    test('parses --enricher and -e', () {
      final parser = GhViewOptions.createArgParser();
      check(parser.parse(['--enricher', 'pm-status enrich-prs'])['enricher'])
          .equals('pm-status enrich-prs');
      check(parser.parse(['-e', 'pm-status enrich-prs'])['enricher'])
          .equals('pm-status enrich-prs');
    });
  });

  group('fetchEnrichedContext', () {
    final pr = (
      number: 42,
      title: 'Fix issue',
      url: 'https://github.com/dart-lang/tools/pull/42',
      isDraft: false,
      state: 'OPEN',
      reviewDecision: 'APPROVED',
      requestedReviewers: <String>[],
      totalReviewThreads: 0,
      unresolvedReviewThreads: 0,
      mergeable: 'MERGEABLE',
      isInMergeQueue: false,
      headRefName: 'fix-issue',
      headRefOid: 'sha42',
      baseRefName: 'main',
      repository: 'dart-lang/tools',
      repoUrl: 'https://github.com/dart-lang/tools',
      isRepoArchived: false,
      ciStatus: 'SUCCESS',
      updatedAt: DateTime.parse('2026-08-13T20:00:00Z'),
      localStatus: null,
      context: null,
    );

    test('parses mapping by url and repo#number', () async {
      final mockJson = jsonEncode({
        'https://github.com/dart-lang/tools/pull/42':
            'Project: [dash-web](file:///path) #A6ER2',
      });

      final result = await fetchEnrichedContext(
        enricherCommand: 'my-enricher',
        prs: [pr],
        enricherRunner: (cmd, payload) async {
          check(cmd).equals('my-enricher');
          check(payload).contains('"number":42');
          return mockJson;
        },
      );

      check(result['https://github.com/dart-lang/tools/pull/42'])
          .equals('Project: [dash-web](file:///path) #A6ER2');
    });

    test('handles empty or null runner responses gracefully', () async {
      final result = await fetchEnrichedContext(
        enricherCommand: 'my-enricher',
        prs: [pr],
        enricherRunner: (cmd, payload) async => null,
      );
      check(result).isEmpty();
    });

    test('handles malformed JSON gracefully', () async {
      final result = await fetchEnrichedContext(
        enricherCommand: 'my-enricher',
        prs: [pr],
        enricherRunner: (cmd, payload) async => 'invalid json',
      );
      check(result).isEmpty();
    });
  });

  group(
    'renderTerminalReport and renderMarkdownReport with enriched context',
    () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final prWithContext = (
        number: 42,
        title: 'Fix issue',
        url: 'https://github.com/dart-lang/tools/pull/42',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: 'APPROVED',
        requestedReviewers: <String>[],
        totalReviewThreads: 0,
        unresolvedReviewThreads: 0,
        mergeable: 'MERGEABLE',
        isInMergeQueue: false,
        headRefName: 'fix-issue',
        headRefOid: 'sha42',
        baseRefName: 'main',
        repository: 'dart-lang/tools',
        repoUrl: 'https://github.com/dart-lang/tools',
        isRepoArchived: false,
        ciStatus: 'SUCCESS',
        updatedAt: now.subtract(const Duration(hours: 1)),
        localStatus: null,
        context: '🎯 [dash-web](file:///projects/dash-web) · #A6ER2',
      );

      test('renderTerminalReport includes Context line', () {
        final output = renderTerminalReport([prWithContext], currentTime: now);
        check(output).contains(
          'Context: 🎯 [dash-web](file:///projects/dash-web) · #A6ER2',
        );
      });

      test('renderMarkdownReport includes context line in table cell', () {
        final output = renderMarkdownReport([prWithContext], currentTime: now);
        check(output)
            .contains('🎯 [dash-web](file:///projects/dash-web) · #A6ER2');
      });

      test('renderMarkdownReport sanitizes pipe characters in context', () {
        final prWithPipe = (
          number: 42,
          title: 'Fix issue',
          url: 'https://github.com/dart-lang/tools/pull/42',
          isDraft: false,
          state: 'OPEN',
          reviewDecision: 'APPROVED',
          requestedReviewers: <String>[],
          totalReviewThreads: 0,
          unresolvedReviewThreads: 0,
          mergeable: 'MERGEABLE',
          isInMergeQueue: false,
          headRefName: 'fix-issue',
          headRefOid: 'sha42',
          baseRefName: 'main',
          repository: 'dart-lang/tools',
          repoUrl: 'https://github.com/dart-lang/tools',
          isRepoArchived: false,
          ciStatus: 'SUCCESS',
          updatedAt: now.subtract(const Duration(hours: 1)),
          localStatus: null,
          context: 'Project: Foo | Bar',
        );
        final output = renderMarkdownReport([prWithPipe], currentTime: now);
        check(output).contains('Project: Foo / Bar');
        check(output).not((c) => c.contains('Project: Foo | Bar'));
      });
    },
  );
}

Future<List<String>> _capturePrints(Future<void> Function() action) async {
  final prints = <String>[];
  final spec = ZoneSpecification(
    print: (_, _, _, Object? message) {
      prints.add(message.toString());
    },
  );
  await runZoned(action, zoneSpecification: spec);
  return prints;
}
