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

    test(
      'retries transient HTTP 502 and 504 errors before succeeding',
      () async {
        var attempts = 0;

        Future<ProcessResult> flakyAsyncRunner(
          String executable,
          List<String> arguments, {
          String? workingDirectory,
        }) async {
          attempts++;
          if (attempts == 1) {
            return ProcessResult(0, 1, '', 'gh: HTTP 504\n');
          }
          if (attempts == 2) {
            return ProcessResult(0, 1, '', 'gh: HTTP 502 Bad Gateway\n');
          }
          final response = {
            'data': {
              'search': {
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
                'nodes': [
                  {'id': 42},
                ],
              },
            },
          };
          return ProcessResult(0, 0, jsonEncode(response), '');
        }

        final results = await paginateGraphQLSearch(
          graphqlQuery: 'query { search { nodes { id } } }',
          searchQuery: 'is:pr is:open',
          limit: 1,
          runner: flakyAsyncRunner,
          exceptionBuilder: (msg, {exitCode = 1}) => Exception(msg),
          retryDelay: (_) => Duration.zero,
        );

        check(attempts).equals(3);
        check(results).length.equals(1);
        check(results.first['id']).equals(42);
      },
    );

    test(
      'does not retry non-transient auth or GraphQL syntax errors',
      () async {
        var attempts = 0;

        Future<ProcessResult> authErrorRunner(
          String executable,
          List<String> arguments, {
          String? workingDirectory,
        }) async {
          attempts++;
          return ProcessResult(0, 4, '', 'gh: HTTP 401 Unauthorized\n');
        }

        await check(
          paginateGraphQLSearch(
            graphqlQuery: 'query { search { nodes { id } } }',
            searchQuery: 'is:pr is:open',
            limit: 1,
            runner: authErrorRunner,
            exceptionBuilder: (msg, {exitCode = 1}) => Exception(msg),
            retryDelay: (_) => Duration.zero,
          ),
        ).throws<Exception>();
        check(attempts).equals(1);
      },
    );
  });

  group('isTransientGhError', () {
    test('identifies HTTP 502, 503, 504 and stream errors', () {
      check(isTransientGhError(ProcessResult(0, 1, '', 'gh: HTTP 502')))
          .isTrue();
      check(isTransientGhError(ProcessResult(0, 1, '', 'gh: HTTP 503')))
          .isTrue();
      check(isTransientGhError(ProcessResult(0, 1, '', 'gh: HTTP 504')))
          .isTrue();
      check(isTransientGhError(ProcessResult(0, 1, '', 'Bad Gateway')))
          .isTrue();
      check(
        isTransientGhError(
          ProcessResult(
            0,
            1,
            '',
            'Something went wrong while executing your query',
          ),
        ),
      ).isTrue();
      check(
        isTransientGhError(
          ProcessResult(0, 1, '', 'stream error: INTERNAL_ERROR'),
        ),
      ).isTrue();
      check(isTransientGhError(ProcessResult(0, 0, '{}', ''))).isFalse();
      check(isTransientGhError(ProcessResult(0, 1, '', 'HTTP 404'))).isFalse();
    });
  });
}
