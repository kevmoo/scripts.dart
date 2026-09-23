import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/pr_triage.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<({int exitCode, List<String> lines})> _capturePrTriage(
  List<String> args,
) async {
  final lines = <String>[];
  final code = await runZoned(
    () => wrappedForTesting(() => runPrTriageCli(args)),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        lines.add(line);
      },
    ),
  );
  return (exitCode: code, lines: lines);
}

Future<
  ({List<String> commitShas, String headSha, String branch, PrContext context})
>
_setupTestGitRepo(Directory dir, {int commits = 1}) async {
  await runCommand('git', ['init'], workingDirectory: dir.path);
  await runCommand('git', [
    'config',
    'user.name',
    'Test User',
  ], workingDirectory: dir.path);
  await runCommand('git', [
    'config',
    'user.email',
    'test@example.com',
  ], workingDirectory: dir.path);

  final shas = <String>[];
  for (var i = 0; i < commits; i++) {
    File(p.join(dir.path, 'file_$i.txt')).writeAsStringSync('hello $i');
    await runCommand('git', ['add', '.'], workingDirectory: dir.path);
    await runCommand('git', [
      'commit',
      '-m',
      'commit $i',
    ], workingDirectory: dir.path);
    final sha = (await runCommand('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: dir.path)).trim();
    shas.add(sha);
  }

  final branch = (await runCommand('git', [
    'symbolic-ref',
    '--short',
    'HEAD',
  ], workingDirectory: dir.path)).trim();

  final context = PrContext(
    workingDir: dir.path,
    prNumber: '1',
    owner: 'testowner',
    repo: 'testrepo',
  );

  return (
    commitShas: shas,
    headSha: shas.isNotEmpty ? shas.last : '',
    branch: branch,
    context: context,
  );
}

void main() {
  _registerGraphQlTests();
  _registerJobLogsTests();
  _registerTriageReportTests();
  _registerSyncStatusTests();
  _registerResolveCliTests();
}

void _registerGraphQlTests() {
  group('fetchPrGraphQLData tests', () {
    late Directory tempDir;
    late PrContext context;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('comments_triage_test_');
      context = PrContext(
        workingDir: tempDir.path,
        prNumber: '38',
        owner: 'dart-lang',
        repo: 'skills',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('extracts reviews, comments, and reviewThreads properly', () async {
      final mockGraphqlData = {
        'data': {
          'repository': {
            'pullRequest': {
              'comments': {
                'nodes': [
                  {
                    'databaseId': 1234567,
                    'author': {'login': 'alice'},
                    'body': 'This is a general conversation comment on the PR.',
                    'createdAt': '2026-08-24T06:00:00Z',
                    'url': 'https://github.com/dart-lang/skills/pull/38#issuecomment-1234567',
                  },
                ],
              },
              'reviews': {
                'nodes': [
                  {
                    'id': 'PRR_kwDORY_9Dc8AAAABKlLgCw',
                    'databaseId': 5005041675,
                    'author': {'login': 'bob'},
                    'body': '',
                    'state': 'COMMENTED',
                    'submittedAt': '2026-08-24T06:24:19Z',
                    'url': 'https://github.com/dart-lang/skills/pull/38#pullrequestreview-5005041675',
                  },
                  {
                    'id': 'PRR_kwDORY_9Dc8AAAABKlMYNQ',
                    'databaseId': 5005056053,
                    'author': {'login': 'kevmoo'},
                    'body':
                        'we should enable (at least) `dart analyze` and '
                        '`dart format` for these files we\'ve added',
                    'state': 'COMMENTED',
                    'submittedAt': '2026-08-24T06:27:09Z',
                    'url': 'https://github.com/dart-lang/skills/pull/38#pullrequestreview-5005056053',
                  },
                ],
              },
              'reviewThreads': {
                'nodes': [
                  {
                    'id': 'PRRT_kwDORY_9Dc8AAAAB12345',
                    'isResolved': false,
                    'comments': {
                      'nodes': [
                        {
                          'databaseId': 9876543,
                          'author': {'login': 'charlie'},
                          'body': 'Please check this line.',
                          'path': 'lib/foo.dart',
                          'line': 42,
                          'originalLine': 42,
                          'createdAt': '2026-08-24T06:10:00Z',
                          'url': 'https://github.com/dart-lang/skills/pull/38#discussion_r9876543',
                        },
                      ],
                    },
                  },
                ],
              },
            },
          },
        },
      };

      final data = await fetchPrGraphQLData(
        context,
        runCommand: (command, args, {workingDirectory}) async {
          expect(command, equals('gh'));
          expect(args, contains('graphql'));
          return jsonEncode(mockGraphqlData);
        },
      );

      expect(data.comments, hasLength(1));
      expect(data.comments.first.author, equals('alice'));
      expect(data.reviews, hasLength(2));
      expect(data.reviewThreads, hasLength(1));
      expect(data.reviewThreads.first.comments.first.line, equals(42));
    });
  });
}

void _registerJobLogsTests() {
  group('fetchFailedCheckLog unit tests', () {
    late Directory tempDir;
    late PrContext context;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('job_logs_test_');
      context = PrContext(
        workingDir: tempDir.path,
        prNumber: '999',
        owner: 'test-owner',
        repo: 'test-repo',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns non-GHA notice when link is not GitHub Actions', () async {
      const check = (
        name: 'Custom Check',
        state: 'FAILURE',
        bucket: 'fail',
        link: 'https://example.com/build/123',
        workflow: 'Custom',
      );

      final result = await fetchFailedCheckLog(context, check);
      expect(result, contains('Non-GitHub Actions run'));
      expect(result, contains('https://example.com/build/123'));
    });

    test('combines check annotations and failed job logs from API', () async {
      const check = (
        name: 'CI / test',
        state: 'FAILURE',
        bucket: 'fail',
        link:
            'https://github.com/test-owner/test-repo/actions/runs/111/job/222',
        workflow: 'CI',
      );

      final result = await fetchFailedCheckLog(
        context,
        check,
        runCommand: _mockAnnotationsAndJobLogsRunner,
      );
      expect(
        result,
        contains('Annotation [failure] lib/foo.dart:42 (Analyze): Bad type'),
      );
      expect(result, contains('--- Job: unit_test (ID: 222) ---'));
      expect(result, contains('Expected: 1\nActual: 2'));
    });

    test('falls back to gh run view --log-failed on empty job logs', () async {
      const check = (
        name: 'CI / test',
        state: 'FAILURE',
        bucket: 'fail',
        link:
            'https://github.com/test-owner/test-repo/actions/runs/111/job/222',
        workflow: 'CI',
      );

      final result = await fetchFailedCheckLog(
        context,
        check,
        runCommand: _mockFallbackRunViewRunner,
      );
      expect(result, contains('Check Annotations:'));
      expect(result, contains('Fallback CLI failure log output'));
    });

    test('parseRunIdFromLink and parseCheckRunIdFromLink extract IDs', () {
      expect(
        parseRunIdFromLink(
          'https://github.com/owner/repo/actions/runs/123456789',
        ),
        equals('123456789'),
      );
      expect(
        parseCheckRunIdFromLink('https://github.com/foo/bar/check-runs/12345'),
        equals('12345'),
      );
      expect(
        parseCheckRunIdFromLink(
          'https://github.com/foo/bar/actions/runs/12345/job/67890',
        ),
        equals('67890'),
      );
    });
  });
}

Future<String> _mockAnnotationsAndJobLogsRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final joined = arguments.join(' ');
  if (joined.contains('check-runs/222/annotations')) {
    return jsonEncode([
      {
        'path': 'lib/foo.dart',
        'start_line': 42,
        'message': 'Bad type',
        'annotation_level': 'failure',
        'title': 'Analyze',
      },
    ]);
  }
  if (joined.contains('actions/runs/111/jobs')) {
    return jsonEncode({
      'jobs': [
        {'id': 222, 'name': 'unit_test', 'conclusion': 'failure'},
        {'id': 223, 'name': 'lint', 'conclusion': 'success'},
      ],
    });
  }
  if (joined.contains('actions/jobs/222/logs')) {
    return 'Expected: 1\nActual: 2';
  }
  throw StateError('Unexpected command: $joined');
}

Future<String> _mockFallbackRunViewRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final joined = arguments.join(' ');
  if (joined.contains('check-runs/222/annotations')) {
    return jsonEncode([
      {
        'path': 'bin/main.dart',
        'start_line': 10,
        'message': 'Compile error',
        'annotation_level': 'failure',
        'title': 'Build',
      },
    ]);
  }
  if (joined.contains('actions/runs/111/jobs')) {
    return jsonEncode({'jobs': <Object>[]});
  }
  if (joined.contains('run view 111 --log-failed')) {
    return 'Fallback CLI failure log output';
  }
  throw StateError('Unexpected command: $joined');
}

void _registerTriageReportTests() {
  group('pr-triage report builder tests', () {
    test(
      'buildTriageReport renders threads, reviews, comments, and checks',
      () {
        final data = (
          prData: <String, dynamic>{
            'number': 42,
            'title': 'Fix parser bug',
            'url': 'https://github.com/o/r/pull/42',
            'headRefName': 'fix-parser',
            'headRefOid': 'abc1234',
            'reviewDecision': 'CHANGES_REQUESTED',
            'mergeable': 'MERGEABLE',
          },
          syncStatus: (
            localBranch: 'fix-parser',
            remoteBranch: 'fix-parser',
            localHeadSha: 'def5678',
            remoteHeadSha: 'abc1234',
            isSynced: false,
            syncState: 'behind_remote',
            warning: 'Local branch is behind remote.',
          ),
          unresolvedThreads: <PrReviewThread>[
            (
              id: 'PRRT_1',
              isResolved: false,
              comments: [
                (
                  databaseId: '9001',
                  path: 'lib/parser.dart',
                  line: 18,
                  body: 'Please handle null\nhere.',
                  author: 'alice',
                  createdAt: '2026-09-18T10:00:00Z',
                  url: 'https://github.com/o/r/pull/42#discussion_r9001',
                ),
              ],
            ),
          ],
          reviewComments: <PrReview>[
            (
              id: 'PRR_1',
              databaseId: '8001',
              state: 'CHANGES_REQUESTED',
              body: 'Needs a unit test.',
              author: 'bob',
              submittedAt: '2026-09-18T10:05:00Z',
              url: 'https://github.com/o/r/pull/42#pullrequestreview-8001',
            ),
          ],
          generalComments: <PrComment>[
            (
              databaseId: '7001',
              path: '',
              line: null,
              body: '/gemini review',
              author: 'kevmoo',
              createdAt: '2026-09-18T10:06:00Z',
              url: 'https://github.com/o/r/pull/42#issuecomment-7001',
            ),
          ],
          failedChecks: <PrCheckRun>[
            (
              name: 'test (ubuntu-latest)',
              state: 'FAILURE',
              bucket: 'fail',
              link: 'https://github.com/o/r/actions/runs/1/job/2',
              workflow: 'CI',
            ),
          ],
          pendingChecks: <PrCheckRun>[
            (
              name: 'test (macos-latest)',
              state: 'IN_PROGRESS',
              bucket: 'pending',
              link: 'https://github.com/o/r/actions/runs/1/job/3',
              workflow: 'CI',
            ),
          ],
          checkLogs: <String, String>{
            'test (ubuntu-latest)': '1 test failed in parser_test.dart',
          },
        );

        final report = buildTriageReport(data);
        expect(report, contains('# PR Triage Report: #42 - Fix parser bug'));
        expect(
          report,
          contains('> [!WARNING]\n> Local branch is behind remote.'),
        );
        expect(report, contains('Thread `PRRT_1`, Comment `9001`'));
        expect(report, contains('### ❌ test (ubuntu-latest)'));
        expect(report, contains('⏳ **test (macos-latest)**'));
      },
    );

    test(
      'buildTriageReport and parseMergeTreeConflictOutput surface conflicts',
      () {
        const mergeTreeSample = '''
c5c7aa93942fd3d8dd7b4300136f7589f5a66b98
lib/src/gh_view/report_renderer.dart
lib/src/git_extensions.dart

Auto-merging lib/src/gh_view/report_renderer.dart
CONFLICT (content): Merge conflict in lib/src/gh_view/report_renderer.dart
Auto-merging lib/src/git_extensions.dart
CONFLICT (content): Merge conflict in lib/src/git_extensions.dart
''';
        final parsed = parseMergeTreeConflictOutput(mergeTreeSample);
        expect(
          parsed.files,
          equals([
            'lib/src/gh_view/report_renderer.dart',
            'lib/src/git_extensions.dart',
          ]),
        );
        expect(parsed.messages, hasLength(2));
      },
    );
  });
}

void _registerSyncStatusTests() {
  group('fetchPrSyncStatus unit tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sync_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'returns in_sync when local and remote SHAs match in git repo',
      () async {
        final setup = await _setupTestGitRepo(tempDir);
        final status = await fetchPrSyncStatus(
          setup.context,
          remoteBranch: setup.branch,
          remoteHeadSha: setup.headSha,
        );
        expect(status.isSynced, isTrue);
        expect(status.syncState, equals('in_sync'));
      },
    );

    test(
      'returns branch_mismatch when active local branch differs from remote',
      () async {
        final setup = await _setupTestGitRepo(tempDir);
        final status = await fetchPrSyncStatus(
          setup.context,
          remoteBranch: 'different-feature-branch',
          remoteHeadSha: setup.headSha,
        );
        expect(status.isSynced, isFalse);
        expect(status.syncState, equals('branch_mismatch'));
      },
    );
  });
}

void _registerResolveCliTests() {
  group('runPrTriageCli resolve validation tests', () {
    test('resolve with no args outputs usage error', () async {
      final res = await _capturePrTriage(['resolve']);
      expect(res.exitCode, equals(ExitCode.usage.code));
      expect(
        res.lines.join('\n'),
        contains('Error: Invalid arguments for resolve subcommand.'),
      );
    });

    test('resolve with non-numeric comment_id outputs usage error', () async {
      final res = await _capturePrTriage([
        'resolve',
        'thread_123',
        'not_a_number',
        'some reply',
      ]);
      expect(res.exitCode, equals(ExitCode.usage.code));
      expect(
        res.lines.join('\n'),
        contains('Error: <comment_id> must be a numeric database ID.'),
      );
    });

    test('resolve with empty body_text outputs usage error', () async {
      final res = await _capturePrTriage([
        'resolve',
        'thread_123',
        '456',
        '   ',
      ]);
      expect(res.exitCode, equals(ExitCode.usage.code));
      expect(
        res.lines.join('\n'),
        contains('Error: <body_text> cannot be empty.'),
      );
    });
  });
}
