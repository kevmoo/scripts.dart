import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/pr_check.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
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
    Map<String, String> gitShowFiles = const {},
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
      if (args.length == 2 && args[0] == 'show') {
        final colonIdx = args[1].indexOf(':');
        final relPath = colonIdx >= 0
            ? args[1].substring(colonIdx + 1)
            : args[1];
        final content = gitShowFiles[relPath];
        if (content != null) {
          return ProcessResult(0, 0, content, '');
        }
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

  test('runs dart pub get before dart analyze when package_config.json is '
      'missing or older than pubspec.yaml', () {
    final pubspecFile = File(p.join(tempDir.path, 'pubspec.yaml'))
      ..writeAsStringSync('''
name: sample_pkg
publish_to: none
environment:
  sdk: ^3.5.0
''');
    final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
    File(p.join(libDir.path, 'foo.dart')).writeAsStringSync('void main() {}\n');

    final missingConfigCalls = <(String, List<String>, String?)>[];
    runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart'],
        recordedCalls: missingConfigCalls,
      ),
    );
    check(
      missingConfigCalls.any(
        (c) => c.$2.length == 2 && c.$2[0] == 'pub' && c.$2[1] == 'get',
      ),
    ).isTrue();

    final dartToolDir = Directory(p.join(tempDir.path, '.dart_tool'))
      ..createSync();
    final pkgConfigFile = File(p.join(dartToolDir.path, 'package_config.json'))
      ..writeAsStringSync('{}\n');
    final now = DateTime.now();
    pubspecFile.setLastModifiedSync(now.subtract(const Duration(seconds: 10)));
    pkgConfigFile.setLastModifiedSync(now);

    final freshConfigCalls = <(String, List<String>, String?)>[];
    runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart'],
        recordedCalls: freshConfigCalls,
      ),
    );
    check(
      freshConfigCalls.any(
        (c) => c.$2.length == 2 && c.$2[0] == 'pub' && c.$2[1] == 'get',
      ),
    ).isFalse();

    pubspecFile.setLastModifiedSync(now.add(const Duration(seconds: 10)));
    final staleConfigCalls = <(String, List<String>, String?)>[];
    runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: ['lib/foo.dart'],
        recordedCalls: staleConfigCalls,
      ),
    );
    check(
      staleConfigCalls.any(
        (c) => c.$2.length == 2 && c.$2[0] == 'pub' && c.$2[1] == 'get',
      ),
    ).isTrue();
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
        'Mentioning `` `<!-- mdformat off/on -->` `` or `` `[TOC]` `` is fine.',
        '`[TOC]`',
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

  test('detects Unicode em/en-dashes in inline CLI flags while allowing dashes '
      'inside fenced code blocks and non-flag inline spans', () {
    final violations = checkGitHubMarkdownLines('skills/sample/SKILL.md', [
      '# Sample Skill',
      '',
      'Run `kscripts pr-check —test` or `[Valid — Fix]` and `8–15`.',
      '',
      '```bash',
      '# Comment — allowed inside fenced code block',
      '```',
    ]);

    check(violations.map((v) => v.check).toList())
        .deepEquals(['markdown-code-unicode-dash']);
  });

  test('checkAgentDocFiles enforces SKILL.md / AGENTS.md character budgets, '
      'frontmatter trigger contract, broken relative links, and unlinked '
      'references/ files', () {
    final skillDir = Directory(p.join(tempDir.path, 'skills', 'bad-skill'))
      ..createSync(recursive: true);
    final refsDir = Directory(p.join(skillDir.path, 'references'))
      ..createSync(recursive: true);
    File(p.join(refsDir.path, 'linked.md')).writeAsStringSync('# Linked\n');
    File(p.join(refsDir.path, 'orphan.md')).writeAsStringSync('# Orphan\n');

    final paddedBody = 'x' * maxSkillMdChars;
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

    final agentsBody = 'x' * (maxAgentsMdChars + 100);
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
      ..contains('agent-doc-char-budget')
      ..contains('skill-frontmatter')
      ..contains('agent-doc-broken-link')
      ..contains('skill-unlinked-reference');
  });

  test('prepareUnpackedConsumerForAnalysis and discoverPubCacheReverseDepNames '
      'sanitize unpacked pubspec files and filter pub-cache directories', () {
    final consumerDir = Directory(
      p.join(tempDir.path, 'json_serializable-6.15.0'),
    )..createSync(recursive: true);
    File(p.join(consumerDir.path, 'analysis_options.yaml'))
        .writeAsStringSync('include: package:lints/recommended.yaml\n');
    File(p.join(consumerDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: json_serializable
version: 6.15.0
resolution: workspace
workspace:
  - example
dependencies:
  source_helper: ^1.3.4
dev_dependencies:
  _shared_test:
    path: ../shared_test
''');

    prepareUnpackedConsumerForAnalysis(
      unpackedDir: consumerDir,
      dependencyName: 'source_helper',
      localDependencyPath: '/local/source_helper',
    );

    check(File(p.join(consumerDir.path, 'analysis_options.yaml')).existsSync())
        .isFalse();
    final sanitizedPubspec = File(p.join(consumerDir.path, 'pubspec.yaml'))
        .readAsStringSync();
    check(sanitizedPubspec)
      ..not((it) => it.contains('resolution:'))
      ..not((it) => it.contains('workspace:'))
      ..not((it) => it.contains('dev_dependencies:'))
      ..contains('source_helper: ^1.3.4');

    final overrides = File(p.join(consumerDir.path, 'pubspec_overrides.yaml'))
        .readAsStringSync();
    check(overrides)
      ..contains('dependency_overrides:')
      ..contains('source_helper:')
      ..contains('path: "/local/source_helper"');

    final fakeHosted = Directory(p.join(tempDir.path, 'pub_cache_hosted'))
      ..createSync(recursive: true);
    final matchDir = Directory(p.join(fakeHosted.path, 'consumer_pkg-1.1.0'))
      ..createSync();
    File(p.join(matchDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: consumer_pkg
dependencies:
  source_helper: ^1.3.0
''');
    final incompatibleDir = Directory(
      p.join(fakeHosted.path, 'older_pkg-2.0.0'),
    )..createSync();
    File(p.join(incompatibleDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: older_pkg
dependencies:
  source_helper: ^0.9.0
''');

    final discovered = discoverPubCacheReverseDepNames(
      'source_helper',
      targetReleaseVersion: Version(1, 4, 0),
      pubCacheHostedDir: fakeHosted,
    );
    check(discovered).deepEquals(['consumer_pkg']);
  });

  test('runPrCheck skips rev-deps by default, runs dart pub unpack + analyze '
      'when runRevDeps is true, and ignores major version bumps', () {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: source_helper
version: 1.4.0-wip
environment:
  sdk: ^3.5.0
''');
    File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 1.4.0-wip

- Add createSortedFieldSet.
''');
    final libDir = Directory(p.join(tempDir.path, 'lib'))..createSync();
    File(p.join(libDir.path, 'source_helper.dart')).writeAsStringSync('''
List<Object> createSortedFieldSet(Object cls) => [];
''');

    final defaultReport = runPrCheck(
      directory: tempDir,
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: [
          'pubspec.yaml',
          'CHANGELOG.md',
          'lib/source_helper.dart',
        ],
        gitShowFiles: {
          'pubspec.yaml': 'name: source_helper\nversion: 1.3.10\n',
        },
      ),
    );
    check(defaultReport.passed).isTrue();
    check(defaultReport.skippedChecks.map((s) => s.toString()).toList())
        .contains('rev-deps:source_helper (pass --rev-deps to run)');

    final optInFailReport = runPrCheck(
      directory: tempDir,
      runRevDeps: true,
      reverseDepNamesLookup: (_) => const ['json_serializable'],
      processRunner: (exe, args, {workingDirectory}) {
        if (args.length >= 3 &&
            args[0] == 'pub' &&
            args[1] == 'unpack' &&
            args[2] == 'json_serializable') {
          final outArg = args.firstWhere((a) => a.startsWith('--output='));
          final outDir = outArg.substring('--output='.length);
          final unpacked = Directory(p.join(outDir, 'json_serializable-6.15.0'))
            ..createSync(recursive: true);
          File(p.join(unpacked.path, 'pubspec.yaml')).writeAsStringSync('''
name: json_serializable
version: 6.15.0
dependencies:
  source_helper: ^1.3.4
''');
          Directory(p.join(unpacked.path, 'lib')).createSync();
          File(p.join(unpacked.path, 'lib', 'json_serializable.dart'))
              .writeAsStringSync('// consumer\n');
          return ProcessResult(0, 0, '', '');
        }
        if (args.length == 2 && args[0] == 'analyze' && args[1] == 'lib') {
          return ProcessResult(
            0,
            3,
            '  error - lib/src/helper.dart:10:5 - A member named '
                "'toStringNonNullable' is defined in two extensions. - "
                'ambiguous_extension_member_access',
            '',
          );
        }
        return fakeGitAndTools(
          exe,
          args,
          workingDirectory: workingDirectory,
          changedFiles: [
            'pubspec.yaml',
            'CHANGELOG.md',
            'lib/source_helper.dart',
          ],
          gitShowFiles: {
            'pubspec.yaml': 'name: source_helper\nversion: 1.3.10\n',
          },
        );
      },
    );

    check(optInFailReport.passed).isFalse();
    check(optInFailReport.violations.map((v) => v.check)).contains('rev-deps');
    check(optInFailReport.violations.single.message)
      ..contains('json_serializable-6.15.0')
      ..contains('ambiguous_extension_member_access');

    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: source_helper
version: 2.0.0-wip
environment:
  sdk: ^3.5.0
''');
    File(p.join(tempDir.path, 'CHANGELOG.md')).writeAsStringSync('''
## 2.0.0-wip

- Breaking release.
''');

    final majorReport = runPrCheck(
      directory: tempDir,
      runRevDeps: true,
      reverseDepNamesLookup: (_) => const ['json_serializable'],
      processRunner: (exe, args, {workingDirectory}) => fakeGitAndTools(
        exe,
        args,
        workingDirectory: workingDirectory,
        changedFiles: [
          'pubspec.yaml',
          'CHANGELOG.md',
          'lib/source_helper.dart',
        ],
        gitShowFiles: {
          'pubspec.yaml': 'name: source_helper\nversion: 1.3.10\n',
        },
      ),
    );
    check(majorReport.passed).isTrue();
  });
}
