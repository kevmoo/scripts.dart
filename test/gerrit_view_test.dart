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
