@TestOn('vm')
library;

import 'package:kevmoo_scripts/src/gerrit_view.dart';
import 'package:test/test.dart';

void main() {
  group('parseGerritCommentsJson', () {
    test('ignores unresolved:true on root when leaf reply resolves', () {
      final commentsByFile = <String, dynamic>{
        'sdk/lib/_http/http_impl.dart': [
          {
            'id': 'root_1',
            'line': 1862,
            'unresolved': true,
            'author': {'_account_id': 999, 'name': 'Lasse Nielsen'},
            'message': 'This text makes me worry.',
          },
          {
            'id': 'reply_1',
            'in_reply_to': 'root_1',
            'line': 1862,
            'unresolved': false,
            'author': {'_account_id': 5005, 'name': 'Kevin Moore'},
            'message': 'Done',
          },
        ],
      };

      final summary = parseGerritCommentsJson(commentsByFile, 5005);
      expect(summary.totalThreads, 1);
      expect(summary.unresolvedReviewerLeaves, 0);
      expect(summary.unresolvedAuthorLeaves, 0);
    });

    test(
      'separates unresolved reviewer leaves from unresolved author leaves',
      () {
        final commentsByFile = <String, dynamic>{
          'file_a.dart': [
            {
              'id': 'slava_root',
              'line': 1812,
              'unresolved': true,
              'author': {'_account_id': 1001, 'name': 'Slava Egorov'},
              'message': 'Cleanup first.',
            },
            {
              'id': 'kevin_leaf',
              'in_reply_to': 'slava_root',
              'line': 1812,
              'unresolved': true,
              'author': {'_account_id': 5005, 'name': 'Kevin Moore'},
              'message': 'How is CL 531300?',
            },
          ],
          'file_b.dart': [
            {
              'id': 'reviewer_leaf',
              'line': 519,
              'unresolved': true,
              'author': {'_account_id': 2002, 'name': 'Nicholas Shahan'},
              'message':
                  'Need similar handling in web_socket_proxy_service.dart',
            },
          ],
        };

        final summary = parseGerritCommentsJson(commentsByFile, 5005);
        expect(summary.totalThreads, 2);
        expect(summary.unresolvedReviewerLeaves, 1);
        expect(summary.unresolvedAuthorLeaves, 1);
      },
    );
    test('groups sibling replies sharing a root and uses latest comment', () {
      final commentsByFile = <String, dynamic>{
        'sdk/lib/_http/http_impl.dart': [
          {
            'id': 'ee446a21_0ecb813b',
            'updated': '2026-08-29 10:00:00.000000000',
            'unresolved': true,
            'author': {'_account_id': 1001, 'name': 'Slava Egorov'},
          },
          {
            'id': '738a887e_77582a4f',
            'in_reply_to': 'ee446a21_0ecb813b',
            'updated': '2026-08-29 12:00:00.000000000',
            'unresolved': true,
            'author': {'_account_id': 5005, 'name': 'Kevin Moore'},
          },
          {
            'id': 'f4534d3e_b03b22fc',
            'in_reply_to': 'ee446a21_0ecb813b',
            'updated': '2026-08-30 01:00:00.000000000',
            'unresolved': false,
            'author': {'_account_id': 5005, 'name': 'Kevin Moore'},
          },
        ],
      };

      final summary = parseGerritCommentsJson(commentsByFile, 5005);
      expect(summary.totalThreads, 1);
      expect(summary.unresolvedReviewerLeaves, 0);
      expect(summary.unresolvedAuthorLeaves, 0);
    });
  });

  group('extractGerritMessagesTelemetry', () {
    test('ignores stale CQ dry run started on an older revision', () {
      final item = <String, dynamic>{
        'created': '2026-08-29 01:00:00.000000000',
        'labels': {
          'Commit-Queue': {'all': <dynamic>[]},
        },
        'messages': [
          {
            '_revision_number': 5,
            'date': '2026-08-30 04:06:04.000000000',
            'author': {'_account_id': 5005},
            'message':
                'Patch Set 5: Commit-Queue+1\nDry run: CV is trying the patch.',
          },
          {
            '_revision_number': 6,
            'date': '2026-08-30 04:10:50.000000000',
            'author': {'_account_id': 5005},
            'message':
                'Uploaded patch set 6: New patch set was added with same tree.',
          },
        ],
      };

      final (lastTouch, cqStatus) = extractGerritMessagesTelemetry(
        item,
        5005,
        6,
      );
      expect(lastTouch, '2026-08-30');
      expect(cqStatus, 'None');
    });
  });

  group('computeGerritNextAction', () {
    test('prioritizes unresolved reviewer comments over awaiting review', () {
      final action = computeGerritNextAction(
        reviewers: ['Nicholas Shahan'],
        crVotes: const [],
        cqStatus: '✅ Passed (2026-05-29)',
        threads: (
          totalThreads: 2,
          unresolvedReviewerLeaves: 1,
          unresolvedAuthorLeaves: 0,
        ),
      );
      expect(action, '❌ Address 1 unresolved reviewer comment(s)');
    });

    test(
      'prioritizes open author-replied threads and negative votes over +1',
      () {
        final pingAction = computeGerritNextAction(
          reviewers: ['Slava Egorov', 'Lasse Nielsen'],
          crVotes: ['Lasse Nielsen:+1'],
          cqStatus: '✅ Passed (2026-08-30)',
          threads: (
            totalThreads: 47,
            unresolvedReviewerLeaves: 0,
            unresolvedAuthorLeaves: 1,
          ),
        );
        expect(
          pingAction,
          '🔔 Ping Slava Egorov, Lasse Nielsen (1 open thread(s))',
        );

        final vetoAction = computeGerritNextAction(
          reviewers: ['Slava Egorov', 'Lasse Nielsen'],
          crVotes: ['Lasse Nielsen:+1', 'Slava Egorov:-1'],
          cqStatus: '✅ Passed (2026-08-30)',
          threads: (
            totalThreads: 47,
            unresolvedReviewerLeaves: 0,
            unresolvedAuthorLeaves: 0,
          ),
        );
        expect(
          vetoAction,
          '❌ Address negative Code-Review (Lasse Nielsen:+1, Slava Egorov:-1)',
        );
      },
    );

    test('flags missing reviewers when 0 reviewers assigned', () {
      final action = computeGerritNextAction(
        reviewers: const [],
        crVotes: const [],
        cqStatus: '✅ Passed (2026-08-30)',
        threads: (
          totalThreads: 4,
          unresolvedReviewerLeaves: 0,
          unresolvedAuthorLeaves: 0,
        ),
      );
      expect(action, '⚠️ Add Reviewer (0 assigned)');
    });
  });
}
