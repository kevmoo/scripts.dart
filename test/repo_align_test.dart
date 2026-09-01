import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/repo_align/canonical_templates.dart';
import 'package:kevmoo_scripts/src/repo_align/models.dart';
import 'package:kevmoo_scripts/src/repo_align/repo_align_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('RepoAlignmentStatus', () {
    test('identifies fully aligned published package', () {
      final status = RepoAlignmentStatus(
        name: 'test_pkg',
        path: '/tmp/test_pkg',
        kind: RepoKind.publishedPackage,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.0.0',
        packageNames: ['test_pkg'],
        hasAnalysisOptions: true,
        analysisInclude:
            'package:dart_flutter_team_lints/analysis_options.yaml',
        strictCasts: true,
        strictInference: true,
        strictRawTypes: true,
        customLints: [],
        workflowFiles: [
          'ci.yml',
          'lower_bound.yml',
          'complexity.yml',
          'autosubmit.yml',
        ],
        hasCi: true,
        hasLowerBound: true,
        hasCogComp: true,
        hasAutosubmit: true,
        hasDependabot: true,
        hasPublish: true,
        autoMergeAllowed: true,
        hasRulesetOrProtection: true,
        requiredChecks: ['analyze (dev)', 'test (ubuntu-latest, dev)'],
      );

      check(status.isAligned).isTrue();
      check(status.issues).isEmpty();
      check(status.hasFullStrictMode).isTrue();
    });

    test('flags missing workflows on published package', () {
      final status = RepoAlignmentStatus(
        name: 'test_pkg',
        path: '/tmp/test_pkg',
        kind: RepoKind.publishedPackage,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.0.0',
        packageNames: ['test_pkg'],
        hasAnalysisOptions: true,
        analysisInclude:
            'package:dart_flutter_team_lints/analysis_options.yaml',
        strictCasts: true,
        strictInference: false,
        strictRawTypes: false,
        customLints: [],
        workflowFiles: ['ci.yml'],
        hasCi: true,
        hasLowerBound: false,
        hasCogComp: false,
        hasAutosubmit: false,
        hasDependabot: false,
        hasPublish: false,
        autoMergeAllowed: false,
        hasRulesetOrProtection: false,
        requiredChecks: [],
      );

      check(status.isAligned).isFalse();
      check(status.issues).contains(
        'Incomplete strict mode (missing: strict-inference, strict-raw-types)',
      );
      check(status.issues).contains('Missing lower_bound.yml');
      check(status.issues).contains('Missing complexity.yml');
      check(status.issues).contains('Missing autosubmit.yml');
      check(status.issues).contains('Missing .github/dependabot.yml');
      check(status.issues)
          .contains('Auto-merge not enabled (allow_auto_merge = false)');
    });

    test('flags CRITICAL issue when auto-merge is enabled with 0 required '
        'status checks', () {
      final status = RepoAlignmentStatus(
        name: 'ungated_repo',
        path: '/tmp/ungated_repo',
        kind: RepoKind.toolOrApp,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.0.0',
        packageNames: ['ungated_repo'],
        hasAnalysisOptions: true,
        analysisInclude:
            'package:dart_flutter_team_lints/analysis_options.yaml',
        strictCasts: true,
        strictInference: true,
        strictRawTypes: true,
        customLints: [],
        workflowFiles: ['ci.yml'],
        hasCi: true,
        hasLowerBound: false,
        hasCogComp: false,
        hasAutosubmit: true,
        hasDependabot: true,
        hasPublish: false,
        autoMergeAllowed: true,
        hasRulesetOrProtection: true,
        requiredChecks: [],
      );

      check(status.isAligned).isFalse();
      check(status.issues).contains(
        'CRITICAL: Auto-merge enabled with 0 required status checks '
        '(ungated merging!)',
      );
    });

    test('flags missing primary CI check when hasCi is true', () {
      final status = RepoAlignmentStatus(
        name: 'ci_repo',
        path: '/tmp/ci_repo',
        kind: RepoKind.toolOrApp,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.0.0',
        packageNames: ['ci_repo'],
        hasAnalysisOptions: true,
        analysisInclude:
            'package:dart_flutter_team_lints/analysis_options.yaml',
        strictCasts: true,
        strictInference: true,
        strictRawTypes: true,
        customLints: [],
        workflowFiles: ['ci.yml'],
        hasCi: true,
        hasLowerBound: false,
        hasCogComp: false,
        hasAutosubmit: true,
        hasDependabot: true,
        hasPublish: false,
        expectedCiCheckPrefixes: ['analyze', 'test'],
        autoMergeAllowed: true,
        hasRulesetOrProtection: true,
        requiredChecks: ['some-random-non-ci-check'],
      );

      check(status.isAligned).isFalse();
      check(status.issues).contains(
        'Branch ruleset missing primary CI check '
        '(expected: analyze/test)',
      );
    });
  });

  group('Canonical Templates', () {
    test('contains expected workflow actions and flags', () {
      check(canonicalLowerBoundWorkflow)
          .contains('kevmoo/analytica.dart/packages/lower_bound@main');
      check(canonicalComplexityWorkflow)
          .contains('kevmoo/analytica.dart/packages/cognitive_complexity@main');
      check(canonicalComplexityWorkflow).contains('fail-threshold: 15');
      check(canonicalComplexityWorkflow).contains('fail-on-increase: true');
      check(canonicalAutosubmitWorkflow).contains('pull_request_target');
      check(canonicalDependabotConfig).contains('package-ecosystem: "pub"');
      check(canonicalAnalysisOptions)
          .contains('package:dart_flutter_team_lints/analysis_options.yaml');
      check(canonicalPublishWorkflow)
          .contains('dart-lang/ecosystem/.github/workflows/publish.yaml@main');
      check(canonicalHealthWorkflow)
          .contains('dart-lang/ecosystem/.github/workflows/health.yaml@main');
      check(canonicalPostSummariesWorkflow).contains(
        'dart-lang/ecosystem/.github/workflows/post_summaries.yaml@main',
      );
    });
  });

  group('publishedPackages', () {
    test('contains bench_press and other known published packages', () {
      check(publishedPackages).contains('bench_press');
      check(publishedPackages).contains('build_cli');
      check(publishedPackages).contains('pubviz');
      check(publishedPackages).contains('stats');
    });
  });

  group('RepoAlignScanner', () {
    test('scans mock directory structure', () {
      final tempDir = Directory.systemTemp.createTempSync('repo_align_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final mockRepo = Directory(p.join(tempDir.path, 'mock_repo'))
        ..createSync();
      File(p.join(mockRepo.path, '.git')).writeAsStringSync('gitdir: ...');
      File(p.join(mockRepo.path, 'pubspec.yaml')).writeAsStringSync('''
name: mock_repo
environment:
  sdk: ^3.0.0
''');
      File(p.join(mockRepo.path, 'analysis_options.yaml')).writeAsStringSync('''
include: package:dart_flutter_team_lints/analysis_options.yaml
analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
''');

      final scanner = RepoAlignScanner(
        baseDirPath: tempDir.path,
        queryGitHubApi: false,
      );
      final results = scanner.scanAll();

      check(results).length.equals(1);
      check(results.first.name).equals('mock_repo');
      check(results.first.hasFullStrictMode).isTrue();
      check(results.first.hasPubspec).isTrue();
    });
  });

  group('clampGhaCheckName', () {
    test('preserves check names <= 100 chars', () {
      const shortName = 'unit_test; Dart 3.9.0; PKG: build_cli; `dart test`';
      check(clampGhaCheckName(shortName)).equals(shortName);

      final exact100 = 'a' * 100;
      check(clampGhaCheckName(exact100)).equals(exact100);
      check(exact100.length).equals(100);
    });

    test('truncates check names > 100 chars with ellipsis to 100 chars', () {
      const longName =
          'analyzer_and_format; Dart 3.9.0; PKGS: build_cli, '
          'build_cli_annotations; `dart analyze --fatal-infos .`';
      check(longName.length).equals(103);

      final clamped = clampGhaCheckName(longName);
      check(clamped.length).equals(100);
      check(clamped).equals(
        'analyzer_and_format; Dart 3.9.0; PKGS: build_cli, '
        'build_cli_annotations; `dart analyze --fatal-in...',
      );
    });
  });
}
