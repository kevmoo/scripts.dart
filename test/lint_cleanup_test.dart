import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/lint_cleanup.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

void main() {
  test('lintCleanupUsage matches expected', () {
    check(lintCleanupUsage).equals('''
-p, --package-dir     The directory to a package within the repository that depends
                      on the referenced include file. Needed for mono repos.
-r, --[no-]rewrite    Rewrites the analysis_options.yaml file to remove duplicative entries.
-h, --help            Prints out usage and exits''');
  });

  test('lintCleanup rewrites redundant rules and language options', () async {
    final tempDir = Directory.systemTemp.createTempSync('lint_cleanup_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final pkgDir = Directory(p.join(tempDir.path, 'my_pkg'))..createSync();
    File(p.join(pkgDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_pkg
environment:
  sdk: ^3.0.0
dependencies:
  dart_flutter_team_lints: ^3.5.2
''');

    File(p.join(pkgDir.path, 'pubspec.lock')).writeAsStringSync('');

    final aoFile = File(p.join(pkgDir.path, 'analysis_options.yaml'))
      ..writeAsStringSync('''
include: package:dart_flutter_team_lints/analysis_options.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true

linter:
  rules:
    - prefer_single_quotes
    - require_trailing_commas
''');

    final scriptsDir = Directory.current;
    await lintCleanup(
      packageDirectory: scriptsDir,
      directoryWithAnalysisOptions: pkgDir,
      rewrite: true,
    );

    final updatedContent = aoFile.readAsStringSync();

    // strict-casts and strict-inference should be removed (in include)
    check(updatedContent).not((c) => c.contains('strict-casts'));
    check(updatedContent).not((c) => c.contains('strict-inference'));
    check(updatedContent).contains('strict-raw-types: true');

    // prefer_single_quotes is in include and should be removed
    check(updatedContent).not((c) => c.contains('prefer_single_quotes'));

    // require_trailing_commas is NOT in include and should be kept
    check(updatedContent).contains('require_trailing_commas');
  });

  test('lintCleanup removes language block if all are redundant', () async {
    final tempDir = Directory.systemTemp.createTempSync('lint_cleanup_lang_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final pkgDir = Directory(p.join(tempDir.path, 'my_pkg'))..createSync();
    final aoFile = File(p.join(pkgDir.path, 'analysis_options.yaml'))
      ..writeAsStringSync('''
include: package:dart_flutter_team_lints/analysis_options.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
''');

    final scriptsDir = Directory.current;
    await lintCleanup(
      packageDirectory: scriptsDir,
      directoryWithAnalysisOptions: pkgDir,
      rewrite: true,
    );

    final updatedContent = aoFile.readAsStringSync();
    check(updatedContent).not((c) => c.contains('analyzer:'));
    check(updatedContent).not((c) => c.contains('language:'));
    check(updatedContent).contains(
      'include: package:dart_flutter_team_lints/analysis_options.yaml',
    );
  });
}
