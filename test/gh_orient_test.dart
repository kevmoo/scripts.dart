import 'dart:convert';

import 'package:kevmoo_scripts/src/gh_orient.dart';
import 'package:kevmoo_scripts/src/gh_orient_audience.dart';
import 'package:test/test.dart';

void main() {
  group('extractPrefix unit tests', () {
    test('extracts bracketed subsystem prefix', () {
      expect(
        extractPrefix('[analyzer] Crash with NullPointer'),
        equals('[analyzer]'),
      );
      expect(
        extractPrefix('[pkg/foo] Bar failure on condition'),
        equals('[pkg/foo]'),
      );
    });

    test('extracts conventional commit prefix with scope', () {
      expect(
        extractPrefix('feat(sidequest): modernize CLI ergonomics'),
        equals('feat(sidequest):'),
      );
      expect(
        extractPrefix('fix(pr-triage): handle empty review array'),
        equals('fix(pr-triage):'),
      );
    });

    test('extracts conventional commit breaking change prefixes', () {
      expect(
        extractPrefix('feat(version)!: breaking API overhaul'),
        equals('feat(version)!:'),
      );
      expect(
        extractPrefix('fix!: breaking fix for auth client'),
        equals('fix!:'),
      );
    });

    test('extracts package colon prefix and normalizes whitespace', () {
      expect(
        extractPrefix('sidequest: add completion order numbers'),
        equals('sidequest:'),
      );
      expect(extractPrefix('fix:   Windows line ending bug'), equals('fix:'));
      expect(
        extractPrefix('request/question: support custom flags'),
        equals('request/question:'),
      );
    });

    test('returns null when title has no recognizable prefix', () {
      expect(extractPrefix('retire "deslop"'), isNull);
      expect(extractPrefix('Just a plain title'), isNull);
    });
  });

  group('isBotAccount unit tests', () {
    test('identifies bot accounts correctly', () {
      expect(isBotAccount('dependabot[bot]'), isTrue);
      expect(isBotAccount('github-actions'), isTrue);
      expect(isBotAccount('app/github-actions'), isTrue);
      expect(isBotAccount('copilot-pull-request-reviewer'), isTrue);
      expect(isBotAccount('renovate-bot'), isTrue);
      expect(isBotAccount('fluttergithubbot'), isTrue);
      expect(isBotAccount('gemini-code-assist'), isTrue);
      expect(isBotAccount('alice'), isFalse);
      expect(isBotAccount('kevmoo'), isFalse);
    });
  });

  group('extractYamlFormFields unit tests', () {
    test('extracts id and label from GitHub issue form YAML', () {
      const yaml = '''
name: Feature request
description: Suggest an idea for this project
body:
  - type: input
    id: command
    attributes:
      label: Command
      description: The command you are running
  - type: textarea
    id: description
    attributes:
      label: Description
  - type: textarea
    id: reasoning
    attributes:
      label: Reasoning
''';
      final fields = extractYamlFormFields(yaml);
      expect(
        fields,
        equals([
          'command (Command)',
          'description (Description)',
          'reasoning (Reasoning)',
        ]),
      );
    });
  });

  group('OrientationGatherer with mock runner', () {
    test('gathers GitHub repository conventions and maintainers', () async {
      final gatherer = OrientationGatherer(runCmd: _mockLocalRepoRunner);
      final orientation = await gatherer.gather(workingDirectory: '/tmp/repo');

      expect(orientation.environment, equals('GitHub'));
      expect(orientation.repoSlug, equals('octocat/Hello-World'));
      expect(orientation.maintainers, containsAll(['alice', 'bob']));
      expect(
        orientation.maintainers,
        isNot(contains('copilot-pull-request-reviewer')),
      );
      expect(orientation.commonIssuePrefixes, contains('[core]'));
      expect(orientation.commonPrPrefixes, contains('feat(core):'));
      expect(
        orientation.detectedLabels,
        containsAll(['bug', 'enhancement', 'documentation']),
      );

      final markdown = orientation.toMarkdown();
      expect(markdown, contains('octocat/Hello-World'));
      expect(markdown, contains('@alice'));
      expect(markdown, contains('@bob'));
      expect(markdown, isNot(contains('@copilot')));
      expect(markdown, contains('`feat(core):`'));
      expect(markdown, contains('`[core]`'));
    });

    test('gathers remote repository conventions via repo parameter', () async {
      final gatherer = OrientationGatherer(runCmd: _mockRemoteRepoRunner);
      final orientation = await gatherer.gather(repo: 'invertase/melos');

      expect(orientation.environment, equals('GitHub'));
      expect(orientation.repoSlug, equals('invertase/melos'));
      expect(orientation.maintainers, contains('dev_user'));
      expect(orientation.commonIssuePrefixes, contains('request:'));
      expect(orientation.commonPrPrefixes, contains('feat(version):'));
      expect(
        orientation.detectedTemplates,
        contains('.github/ISSUE_TEMPLATE/feature_request.yml'),
      );
      expect(
        orientation.detectedTemplates,
        contains('.github/pull_request_template.md'),
      );
      // One distinct PR author and no paths: owner-triaged repository.
      expect(orientation.audience?.mode, equals('owner'));
      expect(orientation.audience?.topPathShare, isNull);
    });

    test(
      'reports owner audience with path authorship on a small repo',
      () async {
        final gatherer = OrientationGatherer(runCmd: _mockLocalRepoRunner);
        final orientation = await gatherer.gather(
          workingDirectory: '/tmp/repo',
          paths: ['lib/src/core.dart'],
        );

        final audience = orientation.audience!;
        expect(audience.mode, equals('owner'));
        expect(audience.distinctPrAuthors, equals(2));
        expect(audience.topPathShare, closeTo(0.75, 0.001));
        expect(audience.topPathAuthors.first, equals('alice (3)'));
        expect(orientation.toMarkdown(), contains('- **Audience**: owner ('));
        expect(orientation.toJson()['audience'], isA<Map<String, dynamic>>());
      },
    );

    test('reports visitor audience on a large distributed repo', () async {
      final gatherer = OrientationGatherer(runCmd: _mockLargeRepoRunner);
      final orientation = await gatherer.gather(
        repo: 'big/project',
        paths: ['packages/foo/lib/foo.dart'],
      );

      final audience = orientation.audience!;
      expect(audience.mode, equals('visitor'));
      expect(audience.distinctPrAuthors, equals(8));
      expect(audience.topPathShare, closeTo(0.4, 0.001));
      expect(audience.evidence, contains('8 distinct merged-PR authors'));
    });
  });

  group('deriveAudience unit tests', () {
    test('small repository is owner-triaged regardless of paths', () {
      expect(deriveAudience(distinctPrAuthors: 3).mode, equals('owner'));
      expect(deriveAudience(distinctPrAuthors: 4).mode, equals('visitor'));
    });

    test('dominant path author flips a mid-sized repo to owner', () {
      final dominant = deriveAudience(
        distinctPrAuthors: 6,
        pathAuthorCounts: {'alice': 5, 'bob': 4, 'carol': 1},
      );
      expect(dominant.mode, equals('owner'));
      expect(dominant.evidence, contains('alice 50%'));

      final spread = deriveAudience(
        distinctPrAuthors: 6,
        pathAuthorCounts: {'alice': 4, 'bob': 4, 'carol': 2},
      );
      expect(spread.mode, equals('visitor'));

      final large = deriveAudience(
        distinctPrAuthors: 7,
        pathAuthorCounts: {'alice': 9, 'bob': 1},
      );
      expect(large.mode, equals('visitor'));
    });

    test('many path authors veto a bot-shrunk PR author sample', () {
      // flutter/flutter shape: 20 merged PRs mostly from autorollers leave
      // 2 distinct humans, but the touched file has 8 recent authors.
      final busy = deriveAudience(
        distinctPrAuthors: 2,
        pathAuthorCounts: {
          'a': 3,
          'b': 2,
          'c': 2,
          'd': 1,
          'e': 1,
          'f': 1,
          'g': 1,
          'h': 1,
        },
      );
      expect(busy.mode, equals('visitor'));
      expect(busy.evidence, contains('paths: 8 authors, top a 25%'));
    });

    test('autoroll accounts are bots', () {
      expect(isBotAccount('engine-flutter-autoroll'), isTrue);
      expect(isBotAccount('skia-flutter-autoroll'), isTrue);
    });

    test('countAuthors ignores blanks and null logins', () {
      expect(
        countAuthors(['alice', '', 'null', 'alice', ' bob ']),
        equals({'alice': 2, 'bob': 1}),
      );
    });
  });
}

Future<String> _mockLargeRepoRunner(
  String command,
  List<String> args, {
  String? workingDirectory,
}) async {
  if (command == 'gh' && args.contains('pr')) {
    return jsonEncode([
      for (var i = 0; i < 8; i++)
        {
          'title': 'fix(pkg$i): change $i',
          'author': {'login': 'dev$i'},
          'reviews': <Object>[],
          'labels': <Object>[],
        },
    ]);
  }
  if (command == 'gh' && args.contains('issue')) {
    return jsonEncode(<Object>[]);
  }
  if (command == 'gh' && args.any((a) => a.contains('/commits?path='))) {
    return 'carol\ncarol\ncarol\ncarol\ndave\ndave\ndave\nerin\nerin\nfrank\n';
  }
  if (command == 'gh' && args.contains('api')) {
    return jsonEncode(<Object>[]);
  }
  throw Exception('Unexpected command: $command ${args.join(' ')}');
}

Future<String> _mockLocalRepoRunner(
  String command,
  List<String> args, {
  String? workingDirectory,
}) async {
  if (command == 'git' && args.contains('log')) {
    return 'alice\nalice\nalice\nbob\n';
  }
  if (command == 'gh' && args.contains('view')) {
    return jsonEncode({'nameWithOwner': 'octocat/Hello-World'});
  }
  if (command == 'gh' && args.contains('pr')) {
    return jsonEncode([
      {
        'title': 'feat(core): initial implementation',
        'author': {'login': 'alice'},
        'reviews': [
          {
            'author': {'login': 'bob'},
          },
          {
            'author': {'login': 'copilot-pull-request-reviewer'},
          },
        ],
        'labels': [
          {'name': 'enhancement'},
        ],
      },
      {
        'title': 'fix(core): resolve race condition',
        'author': {'login': 'bob'},
        'reviews': <Object>[],
        'labels': [
          {'name': 'bug'},
        ],
      },
    ]);
  }
  if (command == 'gh' && args.contains('issue')) {
    return jsonEncode([
      {
        'title': '[core] Race condition in event bus',
        'author': {'login': 'alice'},
        'labels': [
          {'name': 'bug'},
        ],
      },
      {
        'title': '[docs] Missing setup guide',
        'author': {'login': 'charlie'},
        'labels': [
          {'name': 'documentation'},
        ],
      },
    ]);
  }
  throw Exception('Unexpected command: $command ${args.join(' ')}');
}

Future<String> _mockRemoteRepoRunner(
  String command,
  List<String> args, {
  String? workingDirectory,
}) async {
  if (command == 'gh' &&
      args.contains('pr') &&
      args.contains('invertase/melos')) {
    return jsonEncode([
      {
        'title': 'feat(version): support smart dependent versioning',
        'author': {'login': 'dev_user'},
        'reviews': <Object>[],
        'labels': <Object>[],
      },
    ]);
  }
  if (command == 'gh' &&
      args.contains('issue') &&
      args.contains('invertase/melos')) {
    return jsonEncode([
      {
        'title': 'request: avoid cascading releases',
        'author': {'login': 'dev_user'},
        'labels': <Object>[],
      },
    ]);
  }
  if (command == 'gh' && args.contains('api')) {
    return _mockRemoteApiResponse(args);
  }
  throw Exception('Unexpected command: $command ${args.join(' ')}');
}

String _mockRemoteApiResponse(List<String> args) {
  if (args.contains(
    'repos/invertase/melos/contents/.github/pull_request_template.md',
  )) {
    return jsonEncode({'path': '.github/pull_request_template.md'});
  }
  if (args.contains(
    'repos/invertase/melos/contents/.github/PULL_REQUEST_TEMPLATE',
  )) {
    return jsonEncode(<Object>[]);
  }
  return jsonEncode([
    {
      'path': '.github/ISSUE_TEMPLATE/feature_request.yml',
      'download_url': 'https://example.com/template.yml',
    },
  ]);
}
