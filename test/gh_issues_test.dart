import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/gh_issues.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('buildSearchQuery', () {
    final baseTime = DateTime.parse('2026-09-13T12:00:00Z');

    test('builds query with defaults', () {
      final q = buildSearchQuery(user: '@me', createdDays: 365, now: baseTime);
      check(q).equals(
        'is:issue is:open assignee:@me created:>=2025-09-13 sort:updated-desc',
      );
    });

    test('builds query with specific repo and updated days', () {
      final q = buildSearchQuery(
        user: 'kevmoo',
        repo: 'flutter/flutter',
        lastNDays: 14,
        createdDays: 180,
        now: baseTime,
      );
      check(q).equals(
        'is:issue is:open assignee:kevmoo repo:flutter/flutter '
        'created:>=2026-03-17 updated:>=2026-08-30 sort:updated-desc',
      );
    });

    test('omits created filter when createdDays is 0 or null', () {
      final q = buildSearchQuery(user: '@me', createdDays: 0, now: baseTime);
      check(q).equals('is:issue is:open assignee:@me sort:updated-desc');
    });
  });

  group('parseLinkedPr', () {
    test('parses PR with full repository nameWithOwner', () {
      final pr = parseLinkedPr({
        'number': 192601,
        'url': 'https://github.com/flutter/flutter/pull/192601',
        'state': 'OPEN',
        'repository': {'nameWithOwner': 'flutter/flutter'},
      });

      check(pr).isNotNull();
      check(pr!.number).equals(192601);
      check(pr.url).equals('https://github.com/flutter/flutter/pull/192601');
      check(pr.state).equals('OPEN');
      check(pr.repository).equals('flutter/flutter');
    });

    test('extracts repository from URL when repository is missing', () {
      final pr = parseLinkedPr({
        'number': 123,
        'url': 'https://github.com/dart-lang/test/pull/123',
        'state': 'MERGED',
      });

      check(pr).isNotNull();
      check(pr!.number).equals(123);
      check(pr.repository).equals('dart-lang/test');
      check(pr.state).equals('MERGED');
    });

    test('returns null when number or url is missing', () {
      check(parseLinkedPr({'url': 'https://github.com/foo/bar/pull/1'}))
          .isNull();
      check(parseLinkedPr({'number': 1})).isNull();
    });
  });

  group('parseIssueNode', () {
    test('parses full issue node with labels and closedBy PRs', () {
      final node = {
        'number': 187561,
        'title': 'Autocomplete loses keyboard focus',
        'url': 'https://github.com/flutter/flutter/issues/187561',
        'repository': {
          'nameWithOwner': 'flutter/flutter',
          'url': 'https://github.com/flutter/flutter',
        },
        'createdAt': '2026-06-01T10:00:00Z',
        'updatedAt': '2026-09-12T15:00:00Z',
        'comments': {'totalCount': 4},
        'labels': {
          'nodes': [
            {'name': 'a: text input'},
            {'name': 'c: regression'},
          ],
        },
        'closedByPullRequestsReferences': {
          'nodes': [
            {
              'number': 192601,
              'url': 'https://github.com/flutter/flutter/pull/192601',
              'state': 'OPEN',
              'repository': {'nameWithOwner': 'flutter/flutter'},
            },
          ],
        },
      };

      final issue = parseIssueNode(node);
      check(issue).isNotNull();
      check(issue!.number).equals(187561);
      check(issue.title).equals('Autocomplete loses keyboard focus');
      check(issue.repository).equals('flutter/flutter');
      check(issue.labels).deepEquals(['a: text input', 'c: regression']);
      check(issue.commentsCount).equals(4);
      check(issue.linkedPrs).length.equals(1);
      check(issue.linkedPrs.first.number).equals(192601);
    });

    test('returns null for missing required fields', () {
      check(parseIssueNode({'number': 123})).isNull();
      check(parseIssueNode({'title': 'test'})).isNull();
      check(parseIssueNode({'url': 'https://github.com/foo/bar/issues/1'}))
          .isNull();
    });
  });

  group('renderMarkdownReport', () {
    final now = DateTime.parse('2026-09-13T12:00:00Z');
    const options = GhIssuesOptions();

    test('renders empty state correctly', () {
      final output = renderMarkdownReport(
        [],
        options: options,
        currentTime: now,
      );
      check(output).contains('No open assigned issues found. 🎉');
      check(output).contains('**Total Open Issues** | **0**');
    });

    test('renders issues table with links, labels, and PRs', () {
      final issue1 = (
        number: 101,
        title: 'Fix | issue with pipes',
        url: 'https://github.com/dart-lang/test/issues/101',
        repository: 'dart-lang/test',
        repoUrl: 'https://github.com/dart-lang/test',
        createdAt: now.subtract(const Duration(days: 30)),
        updatedAt: now.subtract(const Duration(days: 2)),
        labels: ['bug', 'p1', 'team-web', 'extra-label'],
        commentsCount: 3,
        linkedPrs: [
          (
            number: 102,
            url: 'https://github.com/dart-lang/test/pull/102',
            state: 'OPEN',
            repository: 'dart-lang/test',
          ),
          (
            number: 55,
            url: 'https://github.com/other-org/other-repo/pull/55',
            state: 'MERGED',
            repository: 'other-org/other-repo',
          ),
        ],
      );

      final output = renderMarkdownReport(
        [issue1],
        options: options,
        currentTime: now,
      );

      check(output).contains('**Total Open Issues** | **1**');
      check(output).contains('🔗 **With Linked PRs** | **1**');
      check(output)
          .contains('[#101](https://github.com/dart-lang/test/issues/101)');
      check(output)
          .contains('[dart-lang/test](https://github.com/dart-lang/test)');
      check(output).contains('Fix / issue with pipes');
      check(output).contains('`bug, p1, team-web (+1)`');
      check(output).contains('🟢 2d ago');
      check(output)
          .contains('🟢 [#102](https://github.com/dart-lang/test/pull/102)');
      check(output).contains(
        '🟣 [other-org/other-repo#55](https://github.com/other-org/other-repo/pull/55)',
      );
      check(output).contains('<!-- mdformat off(prevent table wrapping) -->');
      check(output).contains('<!-- mdformat on -->');
    });
  });

  group('renderJsonOutput', () {
    final now = DateTime.parse('2026-09-13T12:00:00Z');
    const options = GhIssuesOptions(user: 'kevmoo');

    test('serializes issues list to JSON', () {
      final issue = (
        number: 42,
        title: 'Sample Issue',
        url: 'https://github.com/flutter/flutter/issues/42',
        repository: 'flutter/flutter',
        repoUrl: 'https://github.com/flutter/flutter',
        createdAt: now.subtract(const Duration(days: 10)),
        updatedAt: now.subtract(const Duration(days: 1)),
        labels: ['platform-web'],
        commentsCount: 2,
        linkedPrs: [
          (
            number: 43,
            url: 'https://github.com/flutter/flutter/pull/43',
            state: 'OPEN',
            repository: 'flutter/flutter',
          ),
        ],
      );

      final jsonStr = renderJsonOutput(
        [issue],
        options: options,
        currentTime: now,
      );
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      check(decoded['total']).equals(1);
      check(decoded['user']).equals('kevmoo');
      final issues = decoded['issues'] as List<dynamic>;
      check(issues).length.equals(1);
      final item = issues.first as Map<String, dynamic>;
      check(item['number']).equals(42);
      check(item['title']).equals('Sample Issue');
      check(item['repository']).equals('flutter/flutter');
      final prs = item['linkedPrs'] as List<dynamic>;
      check(prs).length.equals(1);
      check((prs.first as Map<String, dynamic>)['number']).equals(43);
    });
  });

  group('runGhIssues with mock process runner', () {
    test('fetches and enriches issues with linked PRs', () async {
      final mockOutput = {
        'data': {
          'search': {
            'issueCount': 1,
            'nodes': [
              {
                'number': 200,
                'title': 'Test Issue',
                'url': 'https://github.com/owner/repo/issues/200',
                'repository': {
                  'nameWithOwner': 'owner/repo',
                  'url': 'https://github.com/owner/repo',
                },
                'createdAt': '2026-08-01T00:00:00Z',
                'updatedAt': '2026-09-10T00:00:00Z',
                'comments': {'totalCount': 1},
                'labels': {
                  'nodes': [
                    {'name': 'enhancement'},
                  ],
                },
                'closedByPullRequestsReferences': {
                  'nodes': <Map<String, dynamic>>[],
                },
              },
            ],
          },
        },
      };

      final timelineOutput = {
        'data': {
          'repository': {
            'issue': {
              'timelineItems': {
                'nodes': [
                  {
                    'source': {
                      'number': 201,
                      'url': 'https://github.com/owner/repo/pull/201',
                      'state': 'OPEN',
                      'repository': {'nameWithOwner': 'owner/repo'},
                    },
                  },
                ],
              },
            },
          },
        },
      };

      Future<ProcessResult> mockRunner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        final queryArg = arguments.firstWhere((a) => a.startsWith('query='));
        if (queryArg.contains('search(')) {
          return ProcessResult(0, 0, jsonEncode(mockOutput), '');
        }
        if (queryArg.contains('timelineItems(')) {
          return ProcessResult(0, 0, jsonEncode(timelineOutput), '');
        }
        return ProcessResult(0, 1, '', 'Unknown query');
      }

      final issues = await fetchAssignedIssues(
        user: '@me',
        processRunner: mockRunner,
      );

      check(issues).length.equals(1);
      final issue = issues.first;
      check(issue.number).equals(200);
      check(issue.linkedPrs).length.equals(1);
      check(issue.linkedPrs.first.number).equals(201);
    });

    test('handles GraphQL process failure gracefully', () async {
      Future<ProcessResult> failingRunner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async => ProcessResult(0, 1, '', 'Bad credentials');

      await check(
        fetchAssignedIssues(user: '@me', processRunner: failingRunner),
      ).throws<GhIssuesException>();
    });
  });
}
