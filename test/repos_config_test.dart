import 'dart:io';

import 'package:checks/checks.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/git_up.dart';
import 'package:kevmoo_scripts/src/repos_config.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_helpers.dart';

void main() {
  test('returns null when repos.yaml is missing or empty', () {
    check(
      loadGitUpRepoConfig(p.join(d.sandbox, 'repo'), homeDirectory: d.sandbox),
    ).isNull();

    File(p.join(d.sandbox, '.config', 'kscripts', 'repos.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# comments only\n');

    check(
      loadGitUpRepoConfig(p.join(d.sandbox, 'repo'), homeDirectory: d.sandbox),
    ).isNull();
  });

  test(
    'resolves ~/ paths, symlinks, and ignores other tool sections',
    () async {
      await d.dir('real', [d.dir('sdk')]).create();
      final realSdk = p.join(d.sandbox, 'real', 'sdk');
      final linkSdk = p.join(d.sandbox, 'linked-sdk');
      Link(linkSdk).createSync(realSdk);

      File(p.join(d.sandbox, '.config', 'kscripts', 'repos.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
~/real/sdk:
  other-tool:
    enabled: true
  git-up:
    allowWorktree: true
    branch: core-main
    upstream: upstream-sdk/main
    cleanBranches: false
    before: ""
    post: "echo synced"
~/other/repo:
  other-tool:
    enabled: false
''');

      final config = loadGitUpRepoConfig(linkSdk, homeDirectory: d.sandbox);
      check(config).isNotNull()
        ..has((c) => c.allowWorktree, 'allowWorktree').isTrue()
        ..has((c) => c.branch, 'branch').equals('core-main')
        ..has((c) => c.upstream, 'upstream').equals('upstream-sdk/main')
        ..has((c) => c.cleanBranches, 'cleanBranches').isFalse()
        ..has((c) => c.before, 'before').equals('')
        ..has((c) => c.post, 'post').equals('echo synced')
        ..has((c) => c.override, 'override').isNull();

      check(
        loadGitUpRepoConfig(
          p.join(d.sandbox, 'other', 'repo'),
          homeDirectory: d.sandbox,
        ),
      ).isNull();
    },
  );

  test('rejects unknown keys, bad types, empty branch, duplicates', () async {
    await d.dir('real_target').create();
    final realTarget = p.join(d.sandbox, 'real_target');
    final aliasTarget = p.join(d.sandbox, 'alias_target');
    Link(aliasTarget).createSync(realTarget);

    final cases = <({String yaml, String expectedError})>[
      (yaml: 'foo: [unclosed\n', expectedError: 'Invalid YAML syntax'),
      (
        yaml: 'not-a-map\n',
        expectedError: 'Top-level value must be a YAML map',
      ),
      (
        yaml: 'github/repo:\n  git-up: {}\n',
        expectedError:
            'Repository path "github/repo" must be absolute or start with "~/"',
      ),
      (
        yaml: '~/repo:\n  git-up:\n    allow_worktree: true\n',
        expectedError: 'Unknown key "allow_worktree"',
      ),
      (
        yaml: '~/repo:\n  git-up:\n    allowWorktree: "yes"\n',
        expectedError:
            'Key "allowWorktree" under "~/repo" -> "git-up" must be a boolean.',
      ),
      (
        yaml: '~/repo:\n  git-up:\n    branch: "   "\n',
        expectedError:
            'Key "branch" under "~/repo" -> "git-up" must not be empty.',
      ),
      (
        yaml: '~/real_target:\n  git-up: {}\n~/alias_target:\n  git-up: {}\n',
        expectedError: 'Duplicate repository entries',
      ),
    ];

    final configPath = p.join(d.sandbox, 'bad_repos.yaml');
    for (final testCase in cases) {
      File(configPath).writeAsStringSync(testCase.yaml);
      await capturePrints(() async {
        await check(
          wrappedForTesting(() async {
            loadGitUpRepoConfig(
              realTarget,
              configPath: configPath,
              homeDirectory: d.sandbox,
            );
          }),
        ).throws<GitUpException>(
          (it) => it
            ..has((e) => e.exitCode, 'exitCode').equals(ExitCode.config.code)
            ..has((e) => e.message, 'message').contains(testCase.expectedError),
        );
      });
    }
  });
}
