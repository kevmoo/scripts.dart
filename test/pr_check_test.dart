import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/pr_check.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pr_check_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  ProcessResult fakeGitAndTools(
    String exe,
    List<String> args, {
    String? workingDirectory,
    String statusOut = '',
    List<String> changedFiles = const [],
    int formatExit = 0,
    int analyzeExit = 0,
    int prettierExit = 0,
    int complexityExit = 0,
    int testExit = 0,
    List<(String, List<String>, String?)>? recordedCalls,
  }) {
    recordedCalls?.add((exe, args, workingDirectory));
    if (exe == 'git') {
      if (args.contains('--show-toplevel')) {
        return ProcessResult(0, 0, tempDir.path, '');
      }
      if (args.contains('--porcelain')) {
        return ProcessResult(0, 0, statusOut, '');
      }
      if (args.contains('--verify')) {
        return ProcessResult(0, 0, 'abc1234', '');
      }
      if (args.contains('--name-only')) {
        return ProcessResult(0, 0, changedFiles.join('\n'), '');
      }
    }
    if (args.contains('format')) {
      return ProcessResult(0, formatExit, 'Changed lib/foo.dart', '');
    }
    if (args.contains('analyze')) {
      return ProcessResult(
        0,
        analyzeExit,
        'info - lines_longer_than_80_chars',
        '',
      );
    }
    if (args.contains('run') &&
        args.any((a) => a.startsWith('cognitive_complexity@'))) {
      return ProcessResult(
        0,
        complexityExit,
        'lib/foo.dart:1:1: complexFn score 22 > 15',
        '',
      );
    }
    if (args.length == 1 && args.single == 'test') {
      return ProcessResult(0, testExit, 'Some tests failed.', '');
    }
    if (exe == 'npx') {
      return ProcessResult(0, prettierExit, '[warn] README.md', '');
    }
    return ProcessResult(0, 0, '', '');
  }

  test('detects dirty tracked working tree', () {
    final report = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        statusOut: ' M lib/foo.dart',
      ),
    );

    check(report.passed).isFalse();
    check(report.violations.map((v) => v.check)).contains('git-status');
  });

  test('detects firehose pubspec/CHANGELOG mismatch, missing -wip bump, '
      'and version.dart drift', () {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
version: 1.2.0
environment:
  sdk: ^3.5.0
''');
    File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 1.1.0

- Initial release.
''');
    final libSrc = Directory(p.join(tempDir.path, 'lib', 'src'))
      ..createSync(recursive: true);
    File(p.join(libSrc.path, 'version.dart'))
        .writeAsStringSync("const packageVersion = '1.1.0';\n");
    File(p.join(tempDir.path, 'lib', 'foo.dart'))
        .writeAsStringSync('void main() {}\n');

    final report = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart'],
      ),
    );

    check(report.passed).isFalse();
    final checks = report.violations.map((v) => v.check).toList();
    check(checks).contains('firehose-changelog');
    check(checks).contains('version-dart-sync');
    check(checks).contains('pubspec-wip-bump');
  });

  test(
    'detects missing @TestOn("vm") on dart:io test when workflow runs chrome',
    () {
      File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
publish_to: none
environment:
  sdk: ^3.5.0
''');
      final wfDir = Directory(p.join(tempDir.path, '.github', 'workflows'))
        ..createSync(recursive: true);
      File(p.join(wfDir.path, 'ci.yml')).writeAsStringSync('''
jobs:
  test:
    strategy:
      matrix:
        platform: [vm, chrome]
''');
      final testDir = Directory(p.join(tempDir.path, 'test'))..createSync();
      File(p.join(testDir.path, 'io_only_test.dart')).writeAsStringSync('''
import 'dart:io';
import 'package:test/test.dart';

void main() {}
''');

      final report = runPrCheck(
        directory: tempDir,
        processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
          exe,
          args,
          workingDirectory: workingDirectory,
          changedFiles: ['test/io_only_test.dart'],
        ),
      );

      check(report.passed).isFalse();
      check(report.violations.map((v) => v.check))
          .contains('browser-test-on-vm');
    },
  );

  test('passes cleanly when published package is at -wip version '
      'and tracks passed vs. skipped checks', () {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
version: 1.2.1-wip
environment:
  sdk: ^3.5.0
''');
    File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 1.2.1-wip

- Fix bug.
''');
    final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
    File(p.join(libDir.path, 'foo.dart')).writeAsStringSync('void main() {}\n');

    final report = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart', 'pubspec.yaml', 'CHANGELOG.md'],
      ),
    );

    check(report.passed).isTrue();
    check(report.violations).isEmpty();
    check(report.warnings).isEmpty();
    check(report.passedChecks).contains('git-status');
    check(report.passedChecks).contains('firehose:sample_pkg');
    check(report.passedChecks).contains('dart-format');
    check(report.passedChecks).contains('dart-analyze-fatal-infos');
    check(report.passedChecks).contains('gfm-markdown');
    check(report.skippedChecks.map((s) => s.toString()).toList())
      ..contains('cognitive-complexity (not in workflows)')
      ..contains('browser-test-on-vm (no browser/wasm in workflows)')
      ..contains('prettier-markdown (no .prettierrc.json or workflow)')
      ..contains('dart-test (pass --test to run)');
  });

  test('suggests skip-changelog-check label when package is already -wip '
      'and lib/bin/pubspec changes without CHANGELOG.md update', () {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
version: 1.2.1-wip
environment:
  sdk: ^3.5.0
''');
    File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 1.2.1-wip
''');
    final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
    File(p.join(libDir.path, 'foo.dart')).writeAsStringSync('void main() {}\n');

    final report = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart'],
      ),
    );

    check(report.passed).isTrue();
    check(report.warnings).length.equals(1);
    check(report.warnings.single)
      ..contains('skip-changelog-check')
      ..contains('sample_pkg (1.2.1-wip)')
      ..contains('without updating CHANGELOG.md.');
  });

  test('invokes dart run cognitive_complexity@^<ver> when workflow '
      'references cognitive_complexity', () {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
publish_to: none
environment:
  sdk: ^3.5.0
''');
    final wfDir = Directory(p.join(tempDir.path, '.github', 'workflows'))
      ..createSync(recursive: true);
    File(p.join(wfDir.path, 'complexity.yml')).writeAsStringSync('''
jobs:
  audit:
    steps:
      - uses: kevmoo/analytica.dart/packages/cognitive_complexity@main
''');
    final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
    File(p.join(libDir.path, 'foo.dart')).writeAsStringSync('void main() {}\n');

    final calls = <(String, List<String>, String?)>[];
    final failReport = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart'],
        complexityExit: 1,
        recordedCalls: calls,
      ),
    );

    check(failReport.passed).isFalse();
    check(failReport.violations.map((v) => v.check))
        .contains('cognitive-complexity');
    check(
      calls.any(
        (c) =>
            c.$2.length >= 2 &&
            c.$2[0] == 'run' &&
            c.$2[1] == cognitiveComplexityPackageSpec,
      ),
    ).isTrue();
  });

  test('checkCognitiveComplexityVersionNote emits FYI only when a newer '
      'stable version exists', () {
    check(checkCognitiveComplexityVersionNote(null)).isNull();
    check(checkCognitiveComplexityVersionNote(cognitiveComplexityPinnedVersion))
        .isNull();
    check(checkCognitiveComplexityVersionNote('0.1.0')).isNull();
    check(checkCognitiveComplexityVersionNote('99.0.0-wip')).isNull();
    check(checkCognitiveComplexityVersionNote('99.0.0'))
        .isNotNull()
        .contains('package:cognitive_complexity 99.0.0 is available');
  });

  test(
    'runs dart test only in touched packages with test/ when runTests is true',
    () {
      final pkgADir = Directory(p.join(tempDir.path, 'pkgs', 'pkg_a'))
        ..createSync(recursive: true);
      File(p.join(pkgADir.path, 'pubspec.yaml')).writeAsStringSync('''
name: pkg_a
publish_to: none
''');
      Directory(p.join(pkgADir.path, 'test')).createSync();
      final pkgALib = Directory(p.join(pkgADir.path, 'lib'))..createSync();
      File(p.join(pkgALib.path, 'a.dart')).writeAsStringSync('int a = 1;\n');

      final pkgBDir = Directory(p.join(tempDir.path, 'pkgs', 'pkg_b'))
        ..createSync(recursive: true);
      File(p.join(pkgBDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: pkg_b
publish_to: none
''');
      Directory(p.join(pkgBDir.path, 'test')).createSync();
      final pkgBLib = Directory(p.join(pkgBDir.path, 'lib'))..createSync();
      File(p.join(pkgBLib.path, 'b.dart')).writeAsStringSync('int b = 2;\n');

      final calls = <(String, List<String>, String?)>[];
      final passReport = runPrCheck(
        directory: tempDir,
        runTests: true,
        processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
          exe,
          args,
          workingDirectory: workingDirectory,
          changedFiles: ['pkgs/pkg_a/lib/a.dart'],
          recordedCalls: calls,
        ),
      );

      check(passReport.passed).isTrue();
      check(passReport.passedChecks).contains('dart-test:pkgs/pkg_a');
      final testDirsRun = calls
          .where((c) => c.$2.length == 1 && c.$2.single == 'test')
          .map((c) => c.$3)
          .toList();
      check(testDirsRun).deepEquals([pkgADir.path]);

      final failReport = runPrCheck(
        directory: tempDir,
        runTests: true,
        processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
          exe,
          args,
          workingDirectory: workingDirectory,
          changedFiles: ['pkgs/pkg_a/lib/a.dart'],
          testExit: 1,
        ),
      );
      check(failReport.passed).isFalse();
      check(failReport.violations.map((v) => v.check)).contains('dart-test');
    },
  );

  test(
    'runPrCheckCli prints warnings, Ran, and Skipped coverage lines',
    () async {
      File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
version: 1.2.1-wip
environment:
  sdk: ^3.5.0
''');
      File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 1.2.1-wip
''');
      final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
      File(p.join(libDir.path, 'foo.dart'))
          .writeAsStringSync('void main() {}\n');

      late int exitCode;
      final logs = await capturePrints(() async {
        exitCode = await wrappedForTesting(
          () => runPrCheckCli(
            ['-d', tempDir.path],
            processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
              exe,
              args,
              workingDirectory: workingDirectory,
              changedFiles: ['lib/foo.dart'],
            ),
            fetchLatestCognitiveComplexityVersion: () async => '99.1.0',
          ),
        );
      });

      check(exitCode).equals(0);
      final out = logs.join('\n');
      check(out)
        ..contains('skip-changelog-check')
        ..contains('package:cognitive_complexity 99.1.0 is available')
        ..contains('Ran: git-status, firehose:sample_pkg')
        ..contains('Skipped: cognitive-complexity (not in workflows)');
    },
  );

  test(
    'detects missing -wip bump even when pubspec.yaml itself is modified',
    () {
      File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
version: 1.2.0
environment:
  sdk: ^3.5.0
''');
      File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 1.2.0

- Initial release.
''');

      final report = runPrCheck(
        directory: tempDir,
        processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
          exe,
          args,
          workingDirectory: workingDirectory,
          changedFiles: ['pubspec.yaml'],
        ),
      );

      check(report.passed).isFalse();
      check(report.violations.map((v) => v.check)).contains('pubspec-wip-bump');
    },
  );

  test('does not require -wip bump for .github/ or README.md-only changes', () {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
version: 1.2.0
environment:
  sdk: ^3.5.0
''');
    File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 1.2.0

- Initial release.
''');
    File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Docs\n');

    final report = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['README.md'],
      ),
    );

    check(report.passed).isTrue();
  });

  test('reports dart-format, dart-analyze-fatal-infos, '
      'and prettier-markdown failures', () {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_pkg
publish_to: none
environment:
  sdk: ^3.5.0
''');
    File(p.join(tempDir.path, '.prettierrc.json')).writeAsStringSync('{}\n');
    File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Hi\n');
    final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
    File(p.join(libDir.path, 'foo.dart')).writeAsStringSync('void main() {}\n');

    final report = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart', 'README.md'],
        formatExit: 1,
        analyzeExit: 3,
        prettierExit: 1,
      ),
    );

    check(report.passed).isFalse();
    final checks = report.violations.map((v) => v.check).toList();
    check(checks).contains('dart-format');
    check(checks).contains('dart-analyze-fatal-infos');
    check(checks).contains('prettier-markdown');
  });

  test(
    'detects single-line, collapsible 2-line, nested, and bodyless GFM '
    'alerts and Google3 mdformat/TOC directives outside fenced code blocks',
    () {
      final violations = checkGitHubMarkdownLines('skills/sample/SKILL.md', [
        '# Sample Skill',
        '',
        '> [!NOTE] Inline alert text breaks GitHub rendering.',
        '',
        '> [!WARNING]',
        '> Collapsible 2-line alert without empty `>` line.',
        '',
        '> > [!TIP]',
        '> >',
        '> > Nested blockquote alert is unsupported by GitHub GFM.',
        '',
        '> [!CAUTION]',
        '>',
        'Body text outside blockquote.',
        '',
        '<!-- mdformat off -->',
        '[TOC]',
        'Mentioning `<!-- mdformat off -->` and `[TOC]` in backticks is fine.',
        '',
        '```markdown',
        '> [!NOTE] Inside code fence is ignored.',
        '<!-- mdformat off -->',
        '[TOC]',
        '```',
        '',
        '> [!IMPORTANT]',
        '>',
        '> Valid Prettier-safe GFM alert with empty `>` line.',
        '',
        '> [!NOTE]',
      ]);

      check(violations).length.equals(7);
      check(violations.map((v) => v.check).toList()).deepEquals([
        'gfm-alert-format',
        'gfm-alert-format',
        'gfm-alert-format',
        'gfm-alert-format',
        'gfm-no-google3-directives',
        'gfm-no-google3-directives',
        'gfm-alert-format',
      ]);
    },
  );

  test(
    'detects Unicode em/en-dashes in executable code fences and inline CLI '
    'flags while allowing prose markdown fences and non-flag inline spans',
    () {
      final violations = checkGitHubMarkdownLines('skills/sample/SKILL.md', [
        '# Sample Skill',
        '',
        'Run `kscripts pr-check —test` or `[Valid — Fix]` and `8–15`.',
        '',
        '```bash',
        'kscripts pr-check —dir .',
        '```',
        '',
        '```markdown',
        '# PR Review — Allowed in markdown fence',
        '```',
      ]);

      check(violations.map((v) => v.check).toList()).deepEquals([
        'markdown-code-unicode-dash',
        'markdown-code-unicode-dash',
      ]);
    },
  );

  test('checkAgentDocFiles enforces SKILL.md / AGENTS.md line budgets, '
      'frontmatter trigger contract, broken relative links, and unlinked '
      'references/ files', () {
    final skillDir = Directory(p.join(tempDir.path, 'skills', 'bad-skill'))
      ..createSync(recursive: true);
    final refsDir = Directory(p.join(skillDir.path, 'references'))
      ..createSync(recursive: true);
    File(p.join(refsDir.path, 'linked.md')).writeAsStringSync('# Linked\n');
    File(p.join(refsDir.path, 'orphan.md')).writeAsStringSync('# Orphan\n');

    final paddedBody = List.filled(
      maxSkillMdLines,
      'Line of prose.',
    ).join('\n');
    File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('''
---
name: wrong-name
description:
  Missing folded scalar, missing triggers, has <tag> and `cli --flag`.
---

# Bad Skill

See [linked](references/linked.md), [missing](references/missing.md), and
[`bad_root.md`](/nonexistent/root.md), while ignoring `[example](/ignored.md)`
and `` `[example2](/ignored2.md)` ``.
$paddedBody
''');

    final agentsBody = List.filled(
      maxAgentsMdLines + 5,
      'Rule line.',
    ).join('\n');
    File(p.join(tempDir.path, 'AGENTS.md')).writeAsStringSync(agentsBody);

    final report = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['skills/bad-skill/SKILL.md', 'AGENTS.md'],
      ),
    );

    check(report.passed).isFalse();
    final checks = report.violations.map((v) => v.check).toList();
    check(checks)
      ..contains('agent-doc-line-budget')
      ..contains('skill-frontmatter')
      ..contains('agent-doc-broken-link')
      ..contains('skill-unlinked-reference');
  });
}
