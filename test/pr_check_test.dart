import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/pr_check.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
  }) {
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

  test('detects firehose pubspec/CHANGELOG mismatch, missing -wip bump, and version.dart drift', () {
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
}
