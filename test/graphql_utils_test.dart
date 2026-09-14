import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/shared/graphql_utils.dart';
import 'package:test/test.dart';

void main() {
  group('isBotLogin', () {
    test('detects [bot], -bot, and known bot accounts', () {
      check(isBotLogin('dependabot[bot]')).isTrue();
      check(isBotLogin('codecov-commenter')).isTrue();
      check(isBotLogin('flutter-dashboard')).isTrue();
      check(isBotLogin('custom-bot')).isTrue();
      check(isBotLogin('kevmoo')).isFalse();
      check(isBotLogin('natebosch')).isFalse();
    });
  });

  group('paginateGraphQLSearch & paginateGraphQLSearchSync', () {
    test(
      'paginates multiple pages using endCursor until limit is met',
      () async {
        final calls = <List<String>>[];

        Future<ProcessResult> mockAsyncRunner(
          String executable,
          List<String> arguments, {
          String? workingDirectory,
        }) async {
          calls.add(arguments);
          final hasCursor = arguments.contains('cursor=cursor_1');
          final response = {
            'data': {
              'search': {
                'pageInfo': {
                  'hasNextPage': !hasCursor,
                  'endCursor': hasCursor ? null : 'cursor_1',
                },
                'nodes': [
                  {'id': hasCursor ? 2 : 1},
                ],
              },
            },
          };
          return ProcessResult(0, 0, jsonEncode(response), '');
        }

        final results = await paginateGraphQLSearch(
          graphqlQuery: 'query { search { nodes { id } } }',
          searchQuery: 'is:pr is:open',
          limit: 2,
          runner: mockAsyncRunner,
          exceptionBuilder: (msg, {exitCode = 1}) => Exception(msg),
          maxPageSize: 1,
        );

        check(results).length.equals(2);
        check(results[0]['id']).equals(1);
        check(results[1]['id']).equals(2);
        check(calls).length.equals(2);
        check(calls[1]).contains('cursor=cursor_1');
      },
    );

    test('paginateGraphQLSearchSync paginates synchronously for gh-clean', () {
      var callCount = 0;

      ProcessResult mockSyncRunner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) {
        callCount++;
        final hasCursor = arguments.contains('cursor=page_2');
        final response = {
          'data': {
            'search': {
              'pageInfo': {
                'hasNextPage': !hasCursor,
                'endCursor': hasCursor ? null : 'page_2',
              },
              'nodes': [
                {'number': hasCursor ? 102 : 101},
              ],
            },
          },
        };
        return ProcessResult(0, 0, jsonEncode(response), '');
      }

      final results = paginateGraphQLSearchSync(
        graphqlQuery: 'query { search { nodes { number } } }',
        searchQuery: 'is:pr is:merged',
        limit: 2,
        runner: mockSyncRunner,
        exceptionBuilder: (msg, {exitCode = 1}) => Exception(msg),
        maxPageSize: 1,
      );

      check(results).length.equals(2);
      check(results[0]['number']).equals(101);
      check(results[1]['number']).equals(102);
      check(callCount).equals(2);
    });
  });
}
