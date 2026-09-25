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
      check(pr.reviewDecision).equals(ReviewDecision.reviewRequired);
      check(pr.ciStatus).equals(CiStatus.failure);
      check(pr.mergeable).equals(MergeableState.mergeable);
      check(pr.mergeStateStatus).equals(MergeStateStatus.unknown);
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
      check(pr.ciStatus).equals(CiStatus.treeBroken);
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
      check(pr.ciStatus).equals(CiStatus.failure);
    });
  });

  group('categorizePullRequests', () {
    final now = DateTime.parse('2026-08-13T20:00:00Z');

    GhPr makePr({
      required int number,
      bool isDraft = false,
      bool isRepoArchived = false,
      bool isInMergeQueue = false,
      ReviewDecision reviewDecision = ReviewDecision.none,
      List<String> requestedReviewers = const [],
      List<String> activeReviewers = const [],
      int totalReviewThreads = 0,
      int unresolvedReviewThreads = 0,
      DateTime? lastAuthorCommentAt,
      DateTime? lastReviewerActivityAt,
      CiStatus ciStatus = CiStatus.success,
      MergeableState mergeable = MergeableState.mergeable,
      MergeStateStatus mergeStateStatus = MergeStateStatus.unknown,
    }) => GhPr(
      number: number,
      title: 'PR $number',
      url: 'https://github.com/dart-lang/build/pull/$number',
      isDraft: isDraft,
      state: 'OPEN',
      reviewDecision: reviewDecision,
      requestedReviewers: requestedReviewers,
      activeReviewers: activeReviewers,
      totalReviewThreads: totalReviewThreads,
      unresolvedReviewThreads: unresolvedReviewThreads,
      lastAuthorCommentAt: lastAuthorCommentAt,
      lastReviewerActivityAt: lastReviewerActivityAt,
      mergeable: mergeable,
      mergeStateStatus: mergeStateStatus,
      isInMergeQueue: isInMergeQueue,
      headRefName: 'branch-$number',
      headRefOid: 'sha-$number',
      baseRefName: 'main',
      repository: 'dart-lang/build',
      repoUrl: 'https://github.com/dart-lang/build',
      isRepoArchived: isRepoArchived,
      ciStatus: ciStatus,
      updatedAt: now,
    );

    test(
      'categorizes readyToMerge, actionNeeded, inReview, drafts, archived',
      () {
        final prs = [
          makePr(
            number: 1,
            reviewDecision: ReviewDecision.approved,
            isInMergeQueue: true,
          ),
          makePr(number: 2, reviewDecision: ReviewDecision.changesRequested),
          makePr(
            number: 3,
            reviewDecision: ReviewDecision.reviewRequired,
            ciStatus: CiStatus.failure,
          ),
          makePr(
            number: 4,
            reviewDecision: ReviewDecision.reviewRequired,
            mergeable: MergeableState.conflicting,
          ),
          makePr(number: 5, reviewDecision: ReviewDecision.reviewRequired),
          makePr(number: 6, isDraft: true),
          makePr(number: 7, isRepoArchived: true),
          makePr(
            number: 8,
            reviewDecision: ReviewDecision.changesRequested,
            requestedReviewers: ['harryterkelsen'],
          ),
          makePr(
            number: 9,
            reviewDecision: ReviewDecision.approved,
            mergeStateStatus: MergeStateStatus.blocked,
          ),
        ];

        final cat = categorizePullRequests(prs);
        check(cat.readyToMerge.map((p) => p.number)).deepEquals([1]);
        check(cat.actionNeeded.map((p) => p.number)).deepEquals([2, 3, 4, 9]);
        check(cat.inReview.map((p) => p.number)).deepEquals([5, 8]);
        check(cat.drafts.map((p) => p.number)).deepEquals([6]);
        check(cat.archived.map((p) => p.number)).deepEquals([7]);
      },
    );
  });

  group('renderJsonOutput', () {
    test('serializes structured summary and items', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = GhPr(
        number: 100,
        title: 'Feature XYZ',
        url: 'https://github.com/org/repo/pull/100',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.approved,
        requestedReviewers: ['alice'],
        totalReviewThreads: 5,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.clean,
        isInMergeQueue: false,
        headRefName: 'feat-xyz',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'main',
        repository: 'org/repo',
        repoUrl: 'https://github.com/org/repo',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
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
      check(readyList[0]['mergeStateStatus']).equals('CLEAN');
      final localMap = readyList[0]['local'] as Map<String, dynamic>;
      check(localMap['status']).equals('🟢 Synced');
    });
  });

  group('renderMarkdownReport', () {
    test('renders markdown tables with sections', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = GhPr(
        number: 100,
        title: 'Feature XYZ',
        url: 'https://github.com/org/repo/pull/100',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.approved,
        requestedReviewers: <String>[],
        totalReviewThreads: 0,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.clean,
        isInMergeQueue: true,
        headRefName: 'feat-xyz',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'main',
        repository: 'org/repo',
        repoUrl: 'https://github.com/org/repo',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
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
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('# 🐙 GitHub Pull Request Overview Dashboard');
      check(md).contains(
        '| PR & Repository | Branch & Local Mapping | Review & CI Status | '
        'Last Touched | Action / Ping Status |',
      );
      check(md).contains('## 🚀 1. Ready to Merge');
      check(md).contains('[#100](https://github.com/org/repo/pull/100)');
      check(md).contains('`[🔀 Merge Queue]`');
      check(md).contains('🟢 Synced');
    });

    test('renders blocked by ruleset/branch protection', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = GhPr(
        number: 434,
        title: 'blocked branch protection',
        url: 'https://github.com/genkit-ai/genkit-dart/pull/434',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.approved,
        requestedReviewers: <String>[],
        totalReviewThreads: 0,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.blocked,
        isInMergeQueue: false,
        headRefName: 'blocked-branch',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'main',
        repository: 'genkit-ai/genkit-dart',
        repoUrl: 'https://github.com/genkit-ai/genkit-dart',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
        updatedAt: now.subtract(const Duration(hours: 1)),
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('## ⚠️ 2. Action Needed');
      check(md).contains('🧱 **Blocked by ruleset/branch protection**');
      check(md).contains('Merge:&nbsp;🧱&nbsp;Blocked');
    });

    test(
      'renders Re-review Needed when changes requested but threads resolved',
      () {
        final now = DateTime.parse('2026-08-13T20:00:00Z');
        final pr = GhPr(
          number: 190891,
          title: 'refactor wasm dry-run result handling',
          url: 'https://github.com/flutter/flutter/pull/190891',
          isDraft: false,
          state: 'OPEN',
          reviewDecision: ReviewDecision.changesRequested,
          requestedReviewers: <String>[],
          totalReviewThreads: 12,
          unresolvedReviewThreads: 0,
          mergeable: MergeableState.mergeable,
          mergeStateStatus: MergeStateStatus.unknown,
          isInMergeQueue: false,
          headRefName: 'dry-run-refactor',
          headRefOid: 'abcdef1234567890',
          baseRefName: 'master',
          repository: 'flutter/flutter',
          repoUrl: 'https://github.com/flutter/flutter',
          isRepoArchived: false,
          ciStatus: CiStatus.treeBroken,
          updatedAt: now.subtract(const Duration(hours: 19)),
        );

        final md = renderMarkdownReport([pr], currentTime: now);
        check(md).contains('🔄 **Re-review Needed** (threads resolved)');
        check(md).contains('🔴&nbsp;Changes&nbsp;Requested&nbsp;(Resolved)');
      },
    );

    test('renders Re-review Requested when review requests pending', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = GhPr(
        number: 190891,
        title: 'refactor wasm dry-run result handling',
        url: 'https://github.com/flutter/flutter/pull/190891',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.changesRequested,
        requestedReviewers: ['harryterkelsen'],
        totalReviewThreads: 12,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.unknown,
        isInMergeQueue: false,
        headRefName: 'dry-run-refactor',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'master',
        repository: 'flutter/flutter',
        repoUrl: 'https://github.com/flutter/flutter',
        isRepoArchived: false,
        ciStatus: CiStatus.treeBroken,
        updatedAt: now.subtract(const Duration(hours: 19)),
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('🟡 **Re-review Requested** (@harryterkelsen)');
    });

    test('renders Approved + Awaiting re-review when approved by one '
        'maintainer while another has a queued CHANGES_REQUESTED review', () {
      final now = DateTime.parse('2026-09-25T04:00:00Z');
      final pr = GhPr(
        number: 192964,
        title: '[web] Propagate aria-label to inner slider input',
        url: 'https://github.com/flutter/flutter/pull/192964',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.changesRequested,
        requestedReviewers: ['flutter-zl'],
        activeReviewers: ['flutter-zl', 'chunhtai', 'bystander'],
        reviewAuthors: ['flutter-zl', 'chunhtai'],
        approvedReviewers: ['chunhtai'],
        totalReviewThreads: 1,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.blocked,
        isInMergeQueue: false,
        headRefName: 'web-a11y-pr2-input-aria-label',
        headRefOid: 'e76b483',
        baseRefName: 'master',
        repository: 'flutter/flutter',
        repoUrl: 'https://github.com/flutter/flutter',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
        updatedAt: now.subtract(const Duration(minutes: 30)),
      );

      check(pr.targetReviewers).deepEquals(['flutter-zl']);
      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains(
        '🟡 **Approved (@chunhtai)** · Awaiting @flutter-zl '
        '(or dismiss stale CR)',
      );
      check(md).contains(
        'Review:&nbsp;🟡&nbsp;Re-review&nbsp;Requested&nbsp;(@flutter-zl)&nbsp;'
        '·&nbsp;🟢&nbsp;Approved&nbsp;(@chunhtai)',
      );
      final term = renderTerminalReport([pr], currentTime: now);
      check(term).contains('Re-review Requested (@flutter-zl)');
      check(term).contains('Approved (@chunhtai)');
      final jsonMap = jsonDecode(
        renderJsonOutput([pr], currentTime: now),
      ) as Map<String, dynamic>;
      final inReviewList = jsonMap['inReview'] as List<dynamic>;
      final inReviewPr = inReviewList.single as Map<String, dynamic>;
      check(inReviewPr['approvedReviewers'] as List<dynamic>)
          .deepEquals(['chunhtai']);
    });

    test('renders Ping Reviewer when review required and threads resolved', () {
      final now = DateTime.parse('2026-08-13T20:00:00Z');
      final pr = GhPr(
        number: 2598,
        title: 'Move to Safari drive',
        url: 'https://github.com/dart-lang/test/pull/2598',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.reviewRequired,
        requestedReviewers: ['natebosch'],
        totalReviewThreads: 3,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.unknown,
        isInMergeQueue: false,
        headRefName: 'safari_sily',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'master',
        repository: 'dart-lang/test',
        repoUrl: 'https://github.com/dart-lang/test',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
        updatedAt: now.subtract(const Duration(days: 1)),
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('🔔 **Ping Reviewer** (@natebosch)');
    });

    test('renders Awaiting @... (pinged X ago) when author commented '
        'after last reviewer activity and reviewers are in queue', () {
      final now = DateTime.parse('2026-09-14T20:00:00Z');
      final pr = GhPr(
        number: 2448,
        title: 'Add web coverage support',
        url: 'https://github.com/dart-lang/tools/pull/2448',
        author: 'kevmoo',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.reviewRequired,
        requestedReviewers: [
          'liamappelbe',
          'natebosch',
          'dart-native-runtime-team',
          'dart-ecosystem-team',
        ],
        activeReviewers: ['liamappelbe', 'natebosch'],
        totalReviewThreads: 16,
        unresolvedReviewThreads: 0,
        lastAuthorCommentAt: DateTime.parse('2026-09-14T16:09:46Z'),
        lastReviewerActivityAt: DateTime.parse('2026-09-14T02:01:55Z'),
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.clean,
        isInMergeQueue: false,
        headRefName: 'web_coverage',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'main',
        repository: 'dart-lang/tools',
        repoUrl: 'https://github.com/dart-lang/tools',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
        updatedAt: DateTime.parse('2026-09-14T16:09:46Z'),
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md)
          .contains('⏳ **Awaiting @liamappelbe, @natebosch** (pinged 3h ago)');
      check(md).contains(
        'Review:&nbsp;🟡&nbsp;Review&nbsp;Required&nbsp;'
        '(@liamappelbe,&nbsp;@natebosch)',
      );
    });

    test('renders Re-request Review when active reviewer was dropped from '
        'requestedReviewers even after author PTAL comment', () {
      final now = DateTime.parse('2026-09-23T22:45:00Z');
      final pr = GhPr(
        number: 193187,
        title: 'Clean up suite runner',
        url: 'https://github.com/flutter/flutter/pull/193187',
        author: 'kevmoo',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.reviewRequired,
        requestedReviewers: const [],
        activeReviewers: const ['harryterkelsen'],
        totalReviewThreads: 4,
        unresolvedReviewThreads: 0,
        lastAuthorCommentAt: DateTime.parse('2026-09-23T20:10:00Z'),
        lastReviewerActivityAt: DateTime.parse('2026-09-23T18:00:00Z'),
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.clean,
        isInMergeQueue: false,
        headRefName: 'clean-suite-runner',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'master',
        repository: 'flutter/flutter',
        repoUrl: 'https://github.com/flutter/flutter',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
        updatedAt: DateTime.parse('2026-09-23T20:10:00Z'),
      );

      check(pr.unrequestedActiveReviewers).deepEquals(['harryterkelsen']);
      check(pr.needsReviewReRequest).isTrue();
      final categorized = categorizePullRequests([pr]);
      check(categorized.actionNeeded.map((p) => p.number)).deepEquals([193187]);

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('🔄 **Re-request Review** (@harryterkelsen)');
      check(md).contains(
        'Review:&nbsp;🟠&nbsp;Re-request&nbsp;Review&nbsp;(@harryterkelsen)',
      );
    });

    test('renders Ping Reviewer when author ping is older than 7 days', () {
      final now = DateTime.parse('2026-09-14T20:00:00Z');
      final pr = GhPr(
        number: 1903,
        title: 'cleanup and expand testing',
        url: 'https://github.com/dart-lang/http/pull/1903',
        author: 'kevmoo',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.reviewRequired,
        requestedReviewers: ['brianquinlan'],
        activeReviewers: ['brianquinlan'],
        totalReviewThreads: 4,
        unresolvedReviewThreads: 0,
        lastAuthorCommentAt: now.subtract(const Duration(days: 10)),
        lastReviewerActivityAt: now.subtract(const Duration(days: 12)),
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.blocked,
        isInMergeQueue: false,
        headRefName: 'test_node',
        headRefOid: 'abcdef1234567890',
        baseRefName: 'master',
        repository: 'dart-lang/http',
        repoUrl: 'https://github.com/dart-lang/http',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
        updatedAt: now.subtract(const Duration(days: 4)),
      );

      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains('🔔 **Ping Reviewer** (@brianquinlan)');
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
    final pr = GhPr(
      number: 42,
      title: 'Fix issue',
      url: 'https://github.com/dart-lang/tools/pull/42',
      isDraft: false,
      state: 'OPEN',
      reviewDecision: ReviewDecision.approved,
      requestedReviewers: <String>[],
      totalReviewThreads: 0,
      unresolvedReviewThreads: 0,
      mergeable: MergeableState.mergeable,
      mergeStateStatus: MergeStateStatus.unknown,
      isInMergeQueue: false,
      headRefName: 'fix-issue',
      headRefOid: 'sha42',
      baseRefName: 'main',
      repository: 'dart-lang/tools',
      repoUrl: 'https://github.com/dart-lang/tools',
      isRepoArchived: false,
      ciStatus: CiStatus.success,
      updatedAt: DateTime.parse('2026-08-13T20:00:00Z'),
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
      final prWithContext = GhPr(
        number: 42,
        title: 'Fix issue',
        url: 'https://github.com/dart-lang/tools/pull/42',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.approved,
        requestedReviewers: <String>[],
        totalReviewThreads: 0,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.unknown,
        isInMergeQueue: false,
        headRefName: 'fix-issue',
        headRefOid: 'sha42',
        baseRefName: 'main',
        repository: 'dart-lang/tools',
        repoUrl: 'https://github.com/dart-lang/tools',
        isRepoArchived: false,
        ciStatus: CiStatus.success,
        updatedAt: now.subtract(const Duration(hours: 1)),
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
        final prWithPipe = GhPr(
          number: 42,
          title: 'Fix issue',
          url: 'https://github.com/dart-lang/tools/pull/42',
          isDraft: false,
          state: 'OPEN',
          reviewDecision: ReviewDecision.approved,
          requestedReviewers: <String>[],
          totalReviewThreads: 0,
          unresolvedReviewThreads: 0,
          mergeable: MergeableState.mergeable,
          mergeStateStatus: MergeStateStatus.unknown,
          isInMergeQueue: false,
          headRefName: 'fix-issue',
          headRefOid: 'sha42',
          baseRefName: 'main',
          repository: 'dart-lang/tools',
          repoUrl: 'https://github.com/dart-lang/tools',
          isRepoArchived: false,
          ciStatus: CiStatus.success,
          updatedAt: now.subtract(const Duration(hours: 1)),
          context: 'Project: Foo | Bar',
        );
        final output = renderMarkdownReport([prWithPipe], currentTime: now);
        check(output).contains('Project: Foo / Bar');
        check(output).not((c) => c.contains('Project: Foo | Bar'));
      });
    },
  );

  group('extractCiStatus', () {
    test('extracts ACTION_REQUIRED and correctly identifies it as failing', () {
      final commitNode = {
        'nodes': [
          {
            'commit': {
              'statusCheckRollup': {'state': 'ACTION_REQUIRED'},
            },
          },
        ],
      };

      final status = extractCiStatus('example-org/example-repo', commitNode);
      check(status).equals(CiStatus.actionRequired);
      check(status.isPassing).isFalse();
    });

    test(
      'classifies statusCheckRollup.state == FAILURE as '
      'CiStatus.actionRequired when only ACTION_REQUIRED CheckRuns exist',
      () {
        final commitNode = {
          'nodes': [
            {
              'commit': {
                'statusCheckRollup': {
                  'state': 'FAILURE',
                  'contexts': {
                    'nodes': [
                      {
                        '__typename': 'CheckRun',
                        'name': 'VM Unit Tests (ubuntu-latest, stable)',
                        'conclusion': 'SUCCESS',
                        'status': 'COMPLETED',
                      },
                      {
                        '__typename': 'CheckRun',
                        'name': 'external-integration-check',
                        'conclusion': 'ACTION_REQUIRED',
                        'status': 'COMPLETED',
                      },
                    ],
                  },
                },
              },
            },
          ],
        };

        final status = extractCiStatus('example-org/example-repo', commitNode);
        check(status).equals(CiStatus.actionRequired);
      },
    );

    test('preserves CiStatus.failure when both ACTION_REQUIRED and FAILURE '
        'CheckRuns exist', () {
      final commitNode = {
        'nodes': [
          {
            'commit': {
              'statusCheckRollup': {
                'state': 'FAILURE',
                'contexts': {
                  'nodes': [
                    {
                      '__typename': 'CheckRun',
                      'name': 'VM Unit Tests (ubuntu-latest, stable)',
                      'conclusion': 'FAILURE',
                      'status': 'COMPLETED',
                    },
                    {
                      '__typename': 'CheckRun',
                      'name': 'external-integration-check',
                      'conclusion': 'ACTION_REQUIRED',
                      'status': 'COMPLETED',
                    },
                  ],
                },
              },
            },
          },
        ],
      };

      final status = extractCiStatus('example-org/example-repo', commitNode);
      check(status).equals(CiStatus.failure);
    });

    test(
      'classifies ACTION_REQUIRED CheckRun as CiStatus.failure when text or '
      'summary reports failed jobs, and extracts bullet items into ciDetail',
      () {
        final commitNode = {
          'nodes': [
            {
              'commit': {
                'statusCheckRollup': {
                  'state': 'FAILURE',
                  'contexts': {
                    'nodes': [
                      {
                        '__typename': 'CheckRun',
                        'name': 'Dashboard Checks',
                        'conclusion': 'ACTION_REQUIRED',
                        'status': 'COMPLETED',
                        'title': 'Dashboard Checks',
                        'summary': '**[Failed Presubmit Jobs Details](https://example.com)**',
                        'text':
                            'Failed presubmit jobs:\n'
                            '- `Mac tool_integration_tests_8`\n'
                            '- `Mac_arm64 build_tests_2_5`',
                      },
                    ],
                  },
                },
              },
            },
          ],
        };

        final status = extractCiStatus('flutter/flutter', commitNode);
        check(status).equals(CiStatus.failure);

        final detail = extractCiDetail(commitNode);
        check(detail).equals(
          'Dashboard Checks: Mac tool_integration_tests_8, '
          'Mac_arm64 build_tests_2_5',
        );
      },
    );

    test('extractCiDetail extracts first line of summary for manual '
        'ACTION_REQUIRED gates and renders in Markdown/Terminal reports', () {
      final commitNode = {
        'nodes': [
          {
            'commit': {
              'statusCheckRollup': {
                'state': 'FAILURE',
                'contexts': {
                  'nodes': [
                    {
                      '__typename': 'CheckRun',
                      'name': 'external-integration-check',
                      'conclusion': 'ACTION_REQUIRED',
                      'status': 'COMPLETED',
                      'summary': 'Manual trigger required to run suite',
                    },
                  ],
                },
              },
            },
          },
        ],
      };

      final status = extractCiStatus('example-org/example-repo', commitNode);
      check(status).equals(CiStatus.actionRequired);

      final detail = extractCiDetail(commitNode);
      check(detail).equals(
        'external-integration-check: Manual trigger required to run suite',
      );

      final pr = GhPr(
        number: 99,
        title: 'Test CI detail rendering',
        url: 'https://github.com/example-org/example-repo/pull/99',
        isDraft: false,
        state: 'OPEN',
        reviewDecision: ReviewDecision.reviewRequired,
        requestedReviewers: const ['reviewer1'],
        totalReviewThreads: 0,
        unresolvedReviewThreads: 0,
        mergeable: MergeableState.mergeable,
        mergeStateStatus: MergeStateStatus.blocked,
        isInMergeQueue: false,
        headRefName: 'feat-branch',
        headRefOid: 'abc1234',
        baseRefName: 'main',
        repository: 'example-org/example-repo',
        repoUrl: 'https://github.com/example-org/example-repo',
        isRepoArchived: false,
        ciStatus: status,
        ciDetail: detail,
        updatedAt: DateTime.utc(2026, 9, 24, 18),
      );

      final md = renderMarkdownReport([
        pr,
      ], currentTime: DateTime.utc(2026, 9, 24, 19));
      check(md).contains(
        '🟠 **CI Action Required** '
        '(external-integration-check: Manual trigger required to run suite)',
      );

      final term = renderTerminalReport([
        pr,
      ], currentTime: DateTime.utc(2026, 9, 24, 19));
      check(term).contains(
        'Checks:  external-integration-check: '
        'Manual trigger required to run suite',
      );
    });

    test('extractCiDetail prioritizes real FAILURE checks ahead of collateral '
        'CANCELLED matrix jobs and non-failing ACTION_REQUIRED gates', () {
      final commitNode = {
        'nodes': [
          {
            'commit': {
              'statusCheckRollup': {
                'state': 'FAILURE',
                'contexts': {
                  'nodes': [
                    {
                      '__typename': 'CheckRun',
                      'name': 'CI / test (ubuntu-latest, 3.10)',
                      'conclusion': 'CANCELLED',
                      'status': 'COMPLETED',
                    },
                    {
                      '__typename': 'CheckRun',
                      'name': 'CI / test (macos-latest, 3.10)',
                      'conclusion': 'CANCELLED',
                      'status': 'COMPLETED',
                    },
                    {
                      '__typename': 'CheckRun',
                      'name': 'external-integration-check',
                      'conclusion': 'ACTION_REQUIRED',
                      'status': 'COMPLETED',
                      'summary': '0 failed, 1 pending manual approval',
                    },
                    {
                      '__typename': 'CheckRun',
                      'name': 'CI / test (windows-latest, dev)',
                      'conclusion': 'FAILURE',
                      'status': 'COMPLETED',
                    },
                  ],
                },
              },
            },
          },
        ],
      };

      final detail = extractCiDetail(commitNode);
      check(detail).equals('CI / test (windows-latest, dev)');
    });

    test('sanitizes pipes/tables in ciDetail and handles 0 failed + tree-status', () {
      final commitNode = {
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
                      'name': 'Linux | Integration Gate',
                      'conclusion': 'ACTION_REQUIRED',
                      'status': 'COMPLETED',
                      'summary':
                          '| Stage | Result |\r\n'
                          '|---|---|\r\n'
                          '### 0 failed | Waiting for maintainer approval',
                    },
                  ],
                },
              },
            },
          },
        ],
      };

      final status = extractCiStatus('flutter/flutter', commitNode);
      check(status).equals(CiStatus.actionRequired);

      final detail = extractCiDetail(commitNode);
      check(detail).equals(
        'Linux / Integration Gate: 0 failed / Waiting for maintainer approval',
      );
    });
  });

  group('parsePrNode reviewer and ping detection', () {
    test('detects when author pinged after last reviewer activity', () {
      final node = {
        'number': 2448,
        'title': 'Add web coverage support',
        'url': 'https://github.com/dart-lang/tools/pull/2448',
        'author': {'login': 'kevmoo'},
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'REVIEW_REQUIRED',
        'reviewRequests': {
          'nodes': [
            {
              'requestedReviewer': {'slug': 'dart-native-runtime-team'},
            },
            {
              'requestedReviewer': {'slug': 'dart-ecosystem-team'},
            },
          ],
        },
        'reviews': {
          'nodes': [
            {
              'author': {'login': 'gemini-code-assist'},
              'submittedAt': '2026-09-14T18:00:00Z',
              'state': 'COMMENTED',
            },
            {
              'author': {'login': 'liamappelbe'},
              'submittedAt': '2026-09-14T02:01:55Z',
              'state': 'COMMENTED',
            },
          ],
        },
        'comments': {
          'nodes': [
            {
              'author': {'login': 'natebosch'},
              'body': 'Have you checked google3?',
              'createdAt': '2026-08-18T00:01:57Z',
            },
            {
              'author': {'login': 'kevmoo'},
              'body': '@liamappelbe @natebosch PTAL',
              'createdAt': '2026-09-14T16:09:46Z',
            },
          ],
        },
        'reviewThreads': {
          'totalCount': 16,
          'nodes': [
            {'isResolved': true},
          ],
        },
        'mergeable': 'MERGEABLE',
        'mergeStateStatus': 'CLEAN',
        'isInMergeQueue': false,
        'headRefName': 'web_coverage',
        'headRefOid': 'abc1234',
        'baseRefName': 'main',
        'updatedAt': '2026-09-14T16:09:46Z',
        'repository': {
          'nameWithOwner': 'dart-lang/tools',
          'url': 'https://github.com/dart-lang/tools',
          'isArchived': false,
        },
      };

      final pr = parsePrNode(node)!;
      check(pr.author).equals('kevmoo');
      check(pr.isAlreadyPinged).isTrue();
      check(pr.activeReviewers).deepEquals(['liamappelbe', 'natebosch']);
      check(pr.targetReviewers).deepEquals(['liamappelbe', 'natebosch']);
    });

    test('excludes reviewers whose latest review state is APPROVED from '
        'unrequestedActiveReviewers on multi-reviewer PRs', () {
      Map<String, dynamic> buildNode({String? committedDate}) => {
        'number': 193200,
        'title': 'Multi-reviewer PR',
        'url': 'https://github.com/flutter/flutter/pull/193200',
        'author': {'login': 'kevmoo'},
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'CHANGES_REQUESTED',
        'reviewRequests': {'nodes': <Object>[]},
        'reviews': {
          'nodes': [
            {
              'author': {'login': 'alice'},
              'submittedAt': '2026-09-14T01:00:00Z',
              'state': 'COMMENTED',
            },
            {
              'author': {'login': 'alice'},
              'submittedAt': '2026-09-14T02:00:00Z',
              'state': 'APPROVED',
            },
            {
              'author': {'login': 'bob'},
              'submittedAt': '2026-09-14T03:00:00Z',
              'state': 'CHANGES_REQUESTED',
            },
          ],
        },
        'comments': {'nodes': <Object>[]},
        'reviewThreads': {
          'totalCount': 1,
          'nodes': [
            {'isResolved': true},
          ],
        },
        if (committedDate != null)
          'commits': {
            'nodes': [
              {
                'commit': {
                  'committedDate': committedDate,
                  'statusCheckRollup': {'state': 'SUCCESS'},
                },
              },
            ],
          },
        'mergeable': 'MERGEABLE',
        'mergeStateStatus': 'BLOCKED',
        'isInMergeQueue': false,
        'headRefName': 'multi-reviewer',
        'headRefOid': 'abc1234',
        'baseRefName': 'main',
        'updatedAt': committedDate ?? '2026-09-14T03:00:00Z',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
          'isArchived': false,
        },
      };

      // Before author pushes a fix after bob's CHANGES_REQUESTED:
      final unaddressedPr = parsePrNode(
        buildNode(committedDate: '2026-09-14T00:30:00Z'),
      )!;
      check(unaddressedPr.approvedReviewers).deepEquals(['alice']);
      check(unaddressedPr.activeReviewers).deepEquals(['alice', 'bob']);
      check(unaddressedPr.unrequestedActiveReviewers).deepEquals(['bob']);
      check(unaddressedPr.hasAuthorRespondedSinceLastReview).isFalse();
      check(unaddressedPr.needsReviewReRequest).isFalse();

      // After author pushes a new commit after bob's CHANGES_REQUESTED:
      final addressedPr = parsePrNode(
        buildNode(committedDate: '2026-09-14T04:00:00Z'),
      )!;
      check(addressedPr.unrequestedActiveReviewers).deepEquals(['bob']);
      check(addressedPr.hasAuthorRespondedSinceLastReview).isTrue();
      check(addressedPr.needsReviewReRequest).isTrue();
    });

    test('keeps Changes Requested when reviewer submitted top-level '
        'CHANGES_REQUESTED and author has not responded (#192965)', () {
      final now = DateTime.parse('2026-09-24T06:45:00Z');
      final node = <String, dynamic>{
        'number': 192965,
        'title':
            '[web] Omit group role on menu scrollables and assign region role',
        'url': 'https://github.com/flutter/flutter/pull/192965',
        'author': {'login': 'kevmoo'},
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'CHANGES_REQUESTED',
        'reviewRequests': {'nodes': <Object>[]},
        'reviews': {
          'nodes': [
            {
              'author': {'login': 'flutter-zl'},
              'submittedAt': '2026-09-24T05:56:45Z',
              'state': 'CHANGES_REQUESTED',
            },
          ],
        },
        'comments': {'nodes': <Object>[]},
        'reviewThreads': {
          'totalCount': 2,
          'nodes': [
            {'isResolved': true},
            {'isResolved': true},
          ],
        },
        'commits': {
          'nodes': [
            {
              'commit': {
                'committedDate': '2026-09-23T19:00:00Z',
                'statusCheckRollup': {'state': 'PENDING'},
              },
            },
          ],
        },
        'mergeable': 'MERGEABLE',
        'mergeStateStatus': 'BLOCKED',
        'isInMergeQueue': false,
        'headRefName': 'web-a11y-pr3-menu-route-roles',
        'headRefOid': '88ec987',
        'baseRefName': 'master',
        'updatedAt': '2026-09-24T05:56:45Z',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
          'isArchived': false,
        },
      };

      final pr = parsePrNode(node)!;
      check(pr.needsReviewReRequest).isFalse();
      final md = renderMarkdownReport([pr], currentTime: now);
      check(md).contains(
        'Review:&nbsp;🔴&nbsp;Changes&nbsp;Requested&nbsp;(@flutter-zl)',
      );
      check(md).contains('🔴 **Changes Requested** (@flutter-zl)');
      check(md).not((it) => it.contains('Re-request Review'));
    });

    test('does not flag issue-comment-only or mentioned users as dropped '
        'reviewers when they never submitted a PullRequestReview', () {
      final node = <String, dynamic>{
        'number': 192964,
        'title': '[web] Propagate aria-label to inner slider',
        'url': 'https://github.com/flutter/flutter/pull/192964',
        'author': {'login': 'kevmoo'},
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'REVIEW_REQUIRED',
        'reviewRequests': {
          'nodes': [
            {
              'requestedReviewer': {'login': 'flutter-zl'},
            },
          ],
        },
        'reviews': {'nodes': <Object>[]},
        'comments': {
          'nodes': [
            {
              'author': {'login': 'chunhtai'},
              'body': 'Does this fix #192618?',
              'createdAt': '2026-09-23T21:36:45Z',
            },
            {
              'author': {'login': 'kevmoo'},
              'body': 'Good catch @chunhtai!',
              'createdAt': '2026-09-23T22:09:40Z',
            },
          ],
        },
        'reviewThreads': {'totalCount': 0, 'nodes': <Object>[]},
        'mergeable': 'MERGEABLE',
        'mergeStateStatus': 'BLOCKED',
        'isInMergeQueue': false,
        'headRefName': 'web-a11y-pr2-input-aria-label',
        'headRefOid': 'ff9c244',
        'baseRefName': 'master',
        'updatedAt': '2026-09-23T22:09:40Z',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
          'isArchived': false,
        },
      };

      final pr = parsePrNode(node)!;
      check(pr.reviewAuthors).isNotNull().deepEquals(const <String>[]);
      check(pr.unrequestedActiveReviewers).deepEquals(const <String>[]);
      check(pr.needsReviewReRequest).isFalse();
    });

    test('preserves top-level issue comment mentions and isAlreadyPinged even '
        'when author later replies inside a review thread', () {
      final node = <String, dynamic>{
        'number': 201,
        'title': 'Fix 1 regression test',
        'url': 'https://github.com/org/repo/pull/201',
        'author': {'login': 'kevmoo'},
        'isDraft': false,
        'state': 'OPEN',
        'reviewDecision': 'CHANGES_REQUESTED',
        'reviewRequests': {'nodes': <Object>[]},
        'reviews': {
          'nodes': [
            {
              'author': {'login': 'bob'},
              'submittedAt': '2026-09-24T01:00:00Z',
              'state': 'CHANGES_REQUESTED',
            },
            {
              'author': {'login': 'kevmoo'},
              'submittedAt': '2026-09-24T03:00:00Z',
              'state': 'COMMENTED',
            },
          ],
        },
        'comments': {
          'nodes': [
            {
              'author': {'login': 'kevmoo'},
              'body': 'PTAL @alice @bob',
              'createdAt': '2026-09-24T02:00:00Z',
            },
          ],
        },
        'reviewThreads': {'totalCount': 0, 'nodes': <Object>[]},
        'mergeable': 'MERGEABLE',
        'mergeStateStatus': 'BLOCKED',
        'isInMergeQueue': false,
        'headRefName': 'fix-1',
        'headRefOid': 'abc',
        'baseRefName': 'main',
        'updatedAt': '2026-09-24T03:00:00Z',
        'repository': {
          'nameWithOwner': 'org/repo',
          'url': 'https://github.com/org/repo',
          'isArchived': false,
        },
      };

      final pr = parsePrNode(node)!;
      check(pr.activeReviewers).deepEquals(['alice', 'bob']);
      check(pr.isAlreadyPinged).isTrue();
      check(pr.lastAuthorReviewAt)
          .equals(DateTime.parse('2026-09-24T03:00:00Z'));
      check(pr.hasAuthorRespondedSinceLastReview).isTrue();
    });

    test(
      'bystander issue comment or second reviewer approval after author push '
      'does not suppress needsReviewReRequest for unrequested reviewer',
      () {
        final node = <String, dynamic>{
          'number': 202,
          'title': 'Fix 2 & Fix 4 regression test',
          'url': 'https://github.com/org/repo/pull/202',
          'author': {'login': 'kevmoo'},
          'isDraft': false,
          'state': 'OPEN',
          'reviewDecision': 'CHANGES_REQUESTED',
          'reviewRequests': {'nodes': <Object>[]},
          'reviews': {
            'nodes': [
              {
                'author': {'login': 'bob'},
                'submittedAt': '2026-09-24T01:00:00Z',
                'state': 'CHANGES_REQUESTED',
              },
              {
                'author': {'login': 'alice'},
                'submittedAt': '2026-09-24T03:00:00Z',
                'state': 'APPROVED',
              },
              {
                'author': {'login': 'alice'},
                'submittedAt': '2026-09-24T03:05:00Z',
                'state': 'COMMENTED',
              },
            ],
          },
          'comments': {
            'nodes': [
              {
                'author': {'login': 'bystander'},
                'body': 'Following along!',
                'createdAt': '2026-09-24T04:00:00Z',
              },
            ],
          },
          'reviewThreads': {'totalCount': 0, 'nodes': <Object>[]},
          'commits': {
            'nodes': [
              {
                'commit': {
                  'committedDate': '2026-09-24T02:00:00Z',
                  'statusCheckRollup': {'state': 'SUCCESS'},
                },
              },
            ],
          },
          'mergeable': 'MERGEABLE',
          'mergeStateStatus': 'BLOCKED',
          'isInMergeQueue': false,
          'headRefName': 'fix-2',
          'headRefOid': 'def',
          'baseRefName': 'main',
          'updatedAt': '2026-09-24T04:00:00Z',
          'repository': {
            'nameWithOwner': 'org/repo',
            'url': 'https://github.com/org/repo',
            'isArchived': false,
          },
        };

        final pr = parsePrNode(node)!;
        // Fix 4: alice's APPROVED state is preserved after COMMENTED review.
        check(pr.approvedReviewers).deepEquals(['alice']);
        check(pr.unrequestedActiveReviewers).deepEquals(['bob']);
        check(pr.changesRequestedReviewers).deepEquals(['bob']);
        // Fix 2: author committed at 02:00 (after bob's 01:00 review), even
        // though alice approved at 03:00 and bystander commented at 04:00.
        check(pr.hasAuthorRespondedSinceLastReview).isTrue();
        check(pr.needsReviewReRequest).isTrue();
      },
    );
  });
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
