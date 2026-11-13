import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/repo_align/canonical_templates.dart';
import 'package:kevmoo_scripts/src/repo_align/models.dart';
import 'package:kevmoo_scripts/src/repo_align/repo_align_runner.dart';
import 'package:kevmoo_scripts/src/repo_align/repo_align_scanner.dart';
import 'package:kevmoo_scripts/src/repo_align/workflow_matrix.dart';
import 'package:kevmoo_scripts/src/repos_config.dart';
import 'package:kevmoo_scripts/src/shared/analysis_options_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:yaml/yaml.dart';

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
          'markdown.yml',
        ],
        hasCi: true,
        hasLowerBound: true,
        hasCogComp: true,
        hasAutosubmit: true,
        hasDependabot: true,
        hasPublish: true,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        autoMergeAllowed: true,
        hasRulesetOrProtection: true,
        requiredChecks: [
          'analyze (dev)',
          'test (ubuntu-latest, dev)',
          'markdown',
        ],
        defaultBranchRulesetId: '123',
        defaultBranchRequiredChecks: [
          'analyze (dev)',
          'test (ubuntu-latest, dev)',
          'markdown',
        ],
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

    test('flags missing markdown config on every repo kind', () {
      for (final kind in [
        RepoKind.publishedPackage,
        RepoKind.toolOrApp,
        RepoKind.agentSkills,
      ]) {
        final status = _markdownFixture(kind: kind);
        check(
          because: 'kind $kind',
          status.issues,
        ).contains('Missing .prettierrc.json');
        check(
          because: 'kind $kind',
          status.issues,
        ).contains('Missing markdown.yml');
      }
    });

    test('flags a stray .prettierignore as a regression', () {
      final status = _markdownFixture(
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        hasPrettierIgnore: true,
        requiredChecks: ['markdown'],
      );

      check(status.issues).contains('Stray .prettierignore (should not exist)');
    });

    test('flags markdown.yml that runs but does not gate', () {
      final status = _markdownFixture(
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        requiredChecks: ['analyze (dev)'],
      );

      check(status.issues)
          .contains('markdown.yml present but not a required check');
    });

    test('flags ungated markdown check on agentSkills repos', () {
      final status = _markdownFixture(
        kind: RepoKind.agentSkills,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        requiredChecks: ['validate'],
      );

      check(status.issues)
          .contains('markdown.yml present but not a required check');
    });

    test('flags missing analysis_options.yaml on agentSkills repos with a '
        'pubspec', () {
      final aligned = _markdownFixture(
        kind: RepoKind.agentSkills,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        requiredChecks: ['markdown'],
      );
      final noLints = RepoAlignmentStatus(
        name: aligned.name,
        path: aligned.path,
        kind: RepoKind.agentSkills,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.0.0',
        packageNames: ['skills_repo'],
        hasAnalysisOptions: false,
        analysisInclude: null,
        strictCasts: false,
        strictInference: false,
        strictRawTypes: false,
        customLints: [],
        workflowFiles: ['markdown.yml'],
        hasCi: false,
        hasLowerBound: false,
        hasCogComp: false,
        hasAutosubmit: true,
        hasDependabot: true,
        hasPublish: false,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        autoMergeAllowed: true,
        hasRulesetOrProtection: true,
        requiredChecks: ['markdown'],
        defaultBranchRulesetId: '123',
        defaultBranchRequiredChecks: ['markdown'],
      );

      check(aligned.issues).isEmpty();
      check(noLints.issues).contains('Missing analysis_options.yaml');
      check(noLints.issues).not((it) => it.contains('Missing lower_bound.yml'));
      check(noLints.issues).not((it) => it.contains('Missing complexity.yml'));
    });

    test('does not flag gating when there is no ruleset at all', () {
      final status = _markdownFixture(
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        hasRulesetOrProtection: false,
        requiredChecks: [],
      );

      check(status.issues).not(
        (it) => it.contains('markdown.yml present but not a required check'),
      );
    });

    test('does not flag gating when markdown.yml is absent', () {
      final status = _markdownFixture(requiredChecks: ['analyze (dev)']);

      check(status.issues).not(
        (it) => it.contains('markdown.yml present but not a required check'),
      );
    });

    test('flags non-canonical dependabot, deprecated analytica ref, narrow '
        'path filter, and missing autosubmit label', () {
      final status = _markdownFixture(
        kind: RepoKind.agentSkills,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        requiredChecks: ['markdown'],
      );
      final drifted = RepoAlignmentStatus(
        name: status.name,
        path: status.path,
        kind: RepoKind.agentSkills,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.0.0',
        packageNames: ['skills_repo'],
        hasAnalysisOptions: true,
        analysisInclude:
            'package:dart_flutter_team_lints/analysis_options.yaml',
        strictCasts: true,
        strictInference: true,
        strictRawTypes: true,
        customLints: [],
        workflowFiles: ['validate_skills.yaml', 'markdown.yml'],
        hasCi: true,
        hasLowerBound: false,
        hasCogComp: false,
        hasAutosubmit: true,
        hasDependabot: true,
        hasCanonicalDependabot: false,
        hasDeprecatedAnalyticaRef: true,
        hasNarrowWorkflowsPathFilter: true,
        hasPublish: false,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        autoMergeAllowed: false,
        hasAutosubmitLabel: false,
        hasRulesetOrProtection: true,
        requiredChecks: ['validate', 'markdown'],
        defaultBranchRulesetId: '123',
        defaultBranchRequiredChecks: ['validate', 'markdown'],
      );

      check(drifted.issues).contains(
        'Non-canonical .github/dependabot.yml '
        '(missing grouped github-actions or autosubmit label)',
      );
      check(drifted.issues).contains(
        'Deprecated root action uses: kevmoo/analytica.dart@... '
        '(use packages/cognitive_complexity or kevmoo/lower_bound.dart)',
      );
      check(drifted.issues).contains(
        'Narrow .github/workflows/** path filter in workflow '
        '(use .github/** so dependabot PRs trigger checks)',
      );
      check(drifted.issues)
          .contains('Auto-merge not enabled (allow_auto_merge = false)');
      check(drifted.issues)
          .contains('Missing "autosubmit" label on GitHub repository');
    });

    test('flags missing api_summary dev_dependency, api.txt, and '
        'test/api_test.dart on published repos', () {
      final status = RepoAlignmentStatus(
        name: 'pub_pkg',
        path: '/tmp/pub_pkg',
        kind: RepoKind.publishedPackage,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.12.0',
        packageNames: ['pub_pkg'],
        hasApiSummaryDevDep: false,
        hasApiTxt: false,
        hasApiTest: false,
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
          'markdown.yml',
        ],
        hasCi: true,
        hasLowerBound: true,
        hasCogComp: true,
        hasAutosubmit: true,
        hasDependabot: true,
        hasPublish: true,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        autoMergeAllowed: true,
        hasRulesetOrProtection: true,
        requiredChecks: ['analyze (dev)', 'markdown'],
        defaultBranchRulesetId: '123',
        defaultBranchRequiredChecks: ['analyze (dev)', 'markdown'],
      );

      check(status.isAligned).isFalse();
      check(status.issues).contains('Missing api_summary dev_dependency');
      check(status.issues).contains('Missing api.txt');
      check(status.issues).contains('Missing test/api_test.dart');
    });

    test('does not flag api_summary or lower_bound on unpublished repos', () {
      final status = RepoAlignmentStatus(
        name: 'unpublished_ws',
        path: '/tmp/unpublished_ws',
        kind: RepoKind.monorepoWorkspace,
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        hasPubspec: true,
        sdkConstraint: '^3.12.0',
        packageNames: ['unpublished_ws'],
        hasPublishToNone: true,
        hasApiSummaryDevDep: false,
        hasApiTxt: false,
        hasApiTest: false,
        hasAnalysisOptions: true,
        analysisInclude:
            'package:dart_flutter_team_lints/analysis_options.yaml',
        strictCasts: true,
        strictInference: true,
        strictRawTypes: true,
        customLints: [],
        workflowFiles: [
          'ci.yml',
          'complexity.yml',
          'autosubmit.yml',
          'markdown.yml',
        ],
        hasCi: true,
        hasLowerBound: false,
        hasCogComp: true,
        hasAutosubmit: true,
        hasDependabot: true,
        hasPublish: false,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        autoMergeAllowed: true,
        hasRulesetOrProtection: true,
        requiredChecks: ['analyze (dev)', 'markdown'],
        defaultBranchRulesetId: '123',
        defaultBranchRequiredChecks: ['analyze (dev)', 'markdown'],
      );

      check(status.isAligned).isTrue();
      check(status.issues).isEmpty();
    });
  });

  group('Canonical Templates & Analysis Options Rendering', () {
    test('markdown workflow job id matches the required check context', () {
      check(canonicalMarkdownWorkflow).contains('\n  $markdownCheckContext:\n');
    });

    test('markdown workflow has no paths filter', () {
      check(canonicalMarkdownWorkflow).not((it) => it.contains('\n    paths:'));
    });

    test('renderCanonicalAnalysisOptions preserves analyzer excludes', () {
      final rendered = renderCanonicalAnalysisOptions(
        excludes: ['tool/**', '**/*.g.dart'],
      );
      final parsed = loadYaml(rendered) as YamlMap;
      final analyzer = parsed['analyzer'] as YamlMap;
      final exclude = (analyzer['exclude'] as YamlList).cast<String>();
      final language = analyzer['language'] as YamlMap;

      check(exclude).deepEquals(['tool/**', '**/*.g.dart']);
      check(language['strict-raw-types']).equals(true);
    });

    test('AnalysisOptionsResolver seeds strict mode from canonical include '
        'without PackageConfig', () {
      final resolved = AnalysisOptionsResolver().resolveFromContent(
        canonicalAnalysisOptions,
      );
      check(resolved.allLanguage['strict-casts']).equals(true);
      check(resolved.allLanguage['strict-inference']).equals(true);
      check(resolved.allLanguage['strict-raw-types']).equals(true);
    });
  });

  group('Workflow Matrix Expansion', () {
    test('expands Cartesian os x sdk matrix and respects exclude/include', () {
      const wf = r'''
jobs:
  analyze:
    strategy:
      matrix:
        sdk: [dev]
    steps: []
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
        sdk: ['3.13', dev]
        exclude:
          - os: macos-latest
            sdk: '3.13'
        include:
          - os: windows-latest
            sdk: dev
    steps: []
  named_matrix:
    name: 'test (${{ matrix.os }})'
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps: []
''';

      check(extractWorkflowJobCheckNames(wf)).deepEquals([
        'analyze (dev)',
        'test (ubuntu-latest, 3.13)',
        'test (ubuntu-latest, dev)',
        'test (macos-latest, dev)',
        'test (windows-latest, dev)',
        'test (ubuntu-latest)',
        'test (windows-latest)',
      ]);
    });
  });

  group('RepoAlignScanner', () {
    test('derives RepoKind from contents without hardcoded repo names', () {
      final tempDir = Directory.systemTemp.createTempSync('repo_align_kinds_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      Directory makeRepo(String name) {
        final dir = Directory(p.join(tempDir.path, name))..createSync();
        File(p.join(dir.path, '.git')).writeAsStringSync('gitdir: ...');
        return dir;
      }

      // 1. Published single-package repo
      final pubRepo = makeRepo('synthetic_pub_pkg');
      File(p.join(pubRepo.path, 'pubspec.yaml')).writeAsStringSync('''
name: synthetic_pub_pkg
version: 1.0.0-wip
environment:
  sdk: ^3.12.0
''');

      // 2. Unpublished tool/demo repo (publish_to: none)
      final toolRepo = makeRepo('synthetic_demo_app');
      File(p.join(toolRepo.path, 'pubspec.yaml')).writeAsStringSync('''
name: synthetic_demo_app
version: 0.1.0
publish_to: none
environment:
  sdk: ^3.12.0
''');

      // 3. Pure agent skills workspace (skills/*/SKILL.md, no root lib/bin)
      final skillsRepo = makeRepo('synthetic_skills_bundle');
      File(p.join(skillsRepo.path, 'pubspec.yaml')).writeAsStringSync('''
name: synthetic_skills_bundle
publish_to: none
environment:
  sdk: ^3.12.0
workspace:
  - tool
''');
      Directory(p.join(skillsRepo.path, 'skills', 'demo-skill'))
          .createSync(recursive: true);
      File(p.join(skillsRepo.path, 'skills', 'demo-skill', 'SKILL.md'))
          .writeAsStringSync('---\nname: demo-skill\n---\n');

      // 4. Published package that also co-locates skills/ alongside lib/
      final hybridPkg = makeRepo('synthetic_pkg_with_skill');
      File(p.join(hybridPkg.path, 'pubspec.yaml')).writeAsStringSync('''
name: synthetic_pkg_with_skill
version: 2.0.0
environment:
  sdk: ^3.12.0
''');
      Directory(p.join(hybridPkg.path, 'lib')).createSync();
      Directory(p.join(hybridPkg.path, 'skills', 'helper-skill'))
          .createSync(recursive: true);
      File(p.join(hybridPkg.path, 'skills', 'helper-skill', 'SKILL.md'))
          .writeAsStringSync('---\nname: helper-skill\n---\n');

      final scanner = RepoAlignScanner(
        baseDirPath: tempDir.path,
        queryGitHubApi: false,
      );

      final pubStatus = scanner.scanSingleRepo(pubRepo);
      check(pubStatus.kind).equals(RepoKind.publishedPackage);
      check(pubStatus.requiresLowerBound).isTrue();
      check(pubStatus.requiresApiSummary).isTrue();

      final toolStatus = scanner.scanSingleRepo(toolRepo);
      check(toolStatus.kind).equals(RepoKind.toolOrApp);
      check(toolStatus.requiresLowerBound).isFalse();
      check(toolStatus.requiresApiSummary).isFalse();

      final skillsStatus = scanner.scanSingleRepo(skillsRepo);
      check(skillsStatus.kind).equals(RepoKind.agentSkills);
      check(skillsStatus.requiresLowerBound).isFalse();
      check(skillsStatus.requiresStandardCiWorkflows).isFalse();

      final hybridStatus = scanner.scanSingleRepo(hybridPkg);
      check(hybridStatus.kind).equals(RepoKind.publishedPackage);
    });

    test('classifies workspace with published member as publishedPackage', () {
      final tempDir = Directory.systemTemp.createTempSync('repo_align_ws_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final wsRepo = Directory(p.join(tempDir.path, 'synthetic_ws'))
        ..createSync();
      File(p.join(wsRepo.path, '.git')).writeAsStringSync('gitdir: ...');
      File(p.join(wsRepo.path, 'pubspec.yaml')).writeAsStringSync('''
name: synthetic_ws_root
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - pkg_core
  - pkg_internal
''');
      Directory(p.join(wsRepo.path, 'pkg_core')).createSync();
      File(p.join(wsRepo.path, 'pkg_core', 'pubspec.yaml')).writeAsStringSync(
        'name: pkg_core\nversion: 1.2.0\nresolution: workspace\n'
        'environment:\n  sdk: ^3.6.0\n',
      );
      Directory(p.join(wsRepo.path, 'pkg_internal')).createSync();
      File(p.join(wsRepo.path, 'pkg_internal', 'pubspec.yaml'))
          .writeAsStringSync(
            'name: pkg_internal\npublish_to: none\nresolution: workspace\n'
            'environment:\n  sdk: ^3.6.0\n',
          );

      final scanner = RepoAlignScanner(
        baseDirPath: tempDir.path,
        queryGitHubApi: false,
      );
      final status = scanner.scanSingleRepo(wsRepo);

      check(status.kind).equals(RepoKind.publishedPackage);
      check(status.packageNames).contains('pkg_core');
      check(status.issues).contains('Missing lower_bound.yml');
      check(status.issues).contains('Missing complexity.yml');
    });

    test('repos.yaml kinds override replaces the content-derived kind', () {
      final tempDir = Directory.systemTemp.createTempSync('repo_align_kinds_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final protoRepo = Directory(p.join(tempDir.path, 'proto_app'))
        ..createSync();
      File(p.join(protoRepo.path, '.git')).writeAsStringSync('gitdir: ...');
      File(p.join(protoRepo.path, 'pubspec.yaml')).writeAsStringSync('''
name: proto_app
publish_to: none
environment:
  sdk: ^3.12.0
''');

      final derived = RepoAlignScanner(
        baseDirPath: tempDir.path,
        queryGitHubApi: false,
      ).scanSingleRepo(protoRepo);
      check(derived.kind).equals(RepoKind.toolOrApp);
      check(derived.issues).contains('Missing complexity.yml');

      final overridden = RepoAlignScanner(
        baseDirPath: tempDir.path,
        queryGitHubApi: false,
        portfolioConfig: RepoAlignConfig(
          owner: 'sample-user',
          baseDir: tempDir.path,
          active: const ['proto_app'],
          ignore: const [],
          kinds: const {'proto_app': RepoKind.experimentalOrPrototype},
        ),
      ).scanSingleRepo(protoRepo);
      check(overridden.kind).equals(RepoKind.experimentalOrPrototype);
      check(overridden.issues)
          .not((it) => it.contains('Missing complexity.yml'));
    });

    test('scans uncloned active repos and surfaces unclassified repos via '
        'GraphQL', () {
      final tempDir = Directory.systemTemp.createTempSync('repo_align_gql_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final config = RepoAlignConfig(
        owner: 'sample-user',
        baseDir: tempDir.path,
        active: const ['uncloned_pkg'],
        ignore: const ['ignored_experiment'],
      );

      ProcessResult fakeRunner(
        String executable,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
      }) {
        final queryArg = args.firstWhere((a) => a.startsWith('query='));
        if (queryArg.contains('repositoryOwner')) {
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'data': {
                'repositoryOwner': {
                  'repositories': {
                    'pageInfo': {'hasNextPage': false, 'endCursor': null},
                    'nodes': [
                      {
                        'name': 'uncloned_pkg',
                        'isArchived': false,
                        'isFork': false,
                      },
                      {
                        'name': 'ignored_experiment',
                        'isArchived': false,
                        'isFork': false,
                      },
                      {
                        'name': 'brand_new_repo',
                        'isArchived': false,
                        'isFork': false,
                      },
                      {
                        'name': 'forked_repo',
                        'isArchived': false,
                        'isFork': true,
                      },
                    ],
                  },
                },
              },
            }),
            '',
          );
        }

        return ProcessResult(
          0,
          0,
          jsonEncode({
            'data': {
              'r0': {
                'name': 'uncloned_pkg',
                'isArchived': false,
                'isFork': false,
                'isPrivate': false,
                'autoMergeAllowed': true,
                'defaultBranchRef': {'name': 'main'},
                'autosubmitLabel': {'name': 'autosubmit'},
                'rulesets': {
                  'nodes': [
                    {
                      'databaseId': 99,
                      'name': 'default',
                      'target': 'BRANCH',
                      'enforcement': 'ACTIVE',
                      'conditions': {
                        'refName': {
                          'include': ['~DEFAULT_BRANCH'],
                          'exclude': <String>[],
                        },
                      },
                      'rules': {
                        'nodes': [
                          {
                            'type': 'REQUIRED_STATUS_CHECKS',
                            'parameters': {
                              'requiredStatusChecks': [
                                {'context': 'analyze (dev)'},
                                {'context': 'markdown'},
                              ],
                            },
                          },
                        ],
                      },
                    },
                  ],
                },
                'branchProtectionRules': {'nodes': <Object?>[]},
                'pubspec': {
                  'text':
                      'name: uncloned_pkg\nversion: 1.0.0\n'
                      'environment:\n  sdk: ^3.12.0\n'
                      'dev_dependencies:\n  api_summary: ^1.2.0\n',
                },
                'analysisOptions': {'text': canonicalAnalysisOptions},
                'prettierRc': {'__typename': 'Blob'},
                'prettierIgnore': null,
                'dependabotYml': {'text': canonicalDependabotConfig},
                'dependabotYaml': null,
                'apiTxt': {'__typename': 'Blob'},
                'apiTest': {'__typename': 'Blob'},
                'libDir': {'__typename': 'Tree'},
                'binDir': null,
                'workflows': {
                  'entries': [
                    {
                      'name': 'ci.yml',
                      'object': {
                        'text':
                            'jobs:\n  analyze:\n    strategy:\n'
                            '      matrix:\n        sdk: [dev]\n',
                      },
                    },
                    {
                      'name': 'lower_bound.yml',
                      'object': {'text': canonicalLowerBoundWorkflow},
                    },
                    {
                      'name': 'complexity.yml',
                      'object': {'text': canonicalComplexityWorkflow},
                    },
                    {
                      'name': 'autosubmit.yml',
                      'object': {'text': canonicalAutosubmitWorkflow},
                    },
                    {
                      'name': 'markdown.yml',
                      'object': {'text': canonicalMarkdownWorkflow},
                    },
                  ],
                },
                'skills': null,
                'packages': null,
              },
            },
          }),
          '',
        );
      }

      final scanner = RepoAlignScanner(
        portfolioConfig: config,
        processRunner: fakeRunner,
      );
      final report = scanner.scanPortfolio();

      check(report.repos).length.equals(1);
      final pkg = report.repos.single;
      check(pkg.name).equals('uncloned_pkg');
      check(pkg.kind).equals(RepoKind.publishedPackage);
      check(pkg.isAligned).isTrue();
      check(pkg.issues).isEmpty();
      check(report.unclassifiedRepos).deepEquals(['brand_new_repo']);
    });

    test(
      'ignores subdirectory pubspecs when repo has no root pubspec.yaml',
      () {
        final tempDir = Directory.systemTemp.createTempSync(
          'repo_align_noroot_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final mixedRepo = Directory(p.join(tempDir.path, 'mixed_repo'))
          ..createSync();
        File(p.join(mixedRepo.path, '.git')).writeAsStringSync('gitdir: ...');
        final subPkg = Directory(p.join(mixedRepo.path, 'profile'))
          ..createSync();
        File(p.join(subPkg.path, 'pubspec.yaml')).writeAsStringSync('''
name: profile
environment:
  sdk: ^3.7.0
''');

        final scanner = RepoAlignScanner(
          baseDirPath: tempDir.path,
          queryGitHubApi: false,
        );
        final status = scanner.scanSingleRepo(mixedRepo);

        check(status.hasPubspec).isFalse();
        check(status.issues)
            .not((it) => it.contains('Missing analysis_options.yaml'));
      },
    );

    test('flags uses: kevmoo/analytica.dart/packages/lower_bound@main as '
        'deprecated', () {
      final tempDir = Directory.systemTemp.createTempSync(
        'repo_align_deprecated_lb_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final repoDir = Directory(p.join(tempDir.path, 'mock_pkg'))..createSync();
      File(p.join(repoDir.path, '.git')).writeAsStringSync('gitdir: ...');
      final workflowsDir = Directory(
        p.join(repoDir.path, '.github', 'workflows'),
      )..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'lower_bound.yml')).writeAsStringSync('''
name: Dependency Lower-Bound Validation
on: [pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: kevmoo/analytica.dart/packages/lower_bound@main
''');

      final scanner = RepoAlignScanner(
        baseDirPath: tempDir.path,
        queryGitHubApi: false,
      );
      final status = scanner.scanSingleRepo(repoDir);

      check(status.hasDeprecatedAnalyticaRef).isTrue();
      check(status.issues).contains(
        'Deprecated root action uses: kevmoo/analytica.dart@... '
        '(use packages/cognitive_complexity or kevmoo/lower_bound.dart)',
      );
    });
  });

  group('ruleset payload', () {
    Map<String, dynamic> sampleRuleset() => {
      'id': 21067709,
      'name': 'default',
      'target': 'branch',
      'source_type': 'Repository',
      'source': 'kevmoo/stats',
      'enforcement': 'active',
      'created_at': '2026-01-01T00:00:00Z',
      'current_user_can_bypass': 'always',
      '_links': {
        'self': {'href': '...'},
      },
      'conditions': {
        'ref_name': {
          'include': ['~DEFAULT_BRANCH'],
          'exclude': <String>[],
        },
      },
      'rules': [
        {'type': 'deletion'},
        {'type': 'non_fast_forward'},
        {
          'type': 'required_status_checks',
          'parameters': {
            'strict_required_status_checks_policy': false,
            'do_not_enforce_on_create': false,
            'required_status_checks': [
              {'context': 'analyze (dev)', 'integration_id': 15368},
            ],
          },
        },
      ],
    };

    test('appends the context without disturbing anything else', () {
      final payload = appendRequiredCheck(sampleRuleset(), 'markdown')!;

      check(payload.keys).unorderedEquals([
        'name',
        'target',
        'enforcement',
        'bypass_actors',
        'conditions',
        'rules',
      ]);

      final rules = payload['rules'] as List;
      check(rules).length.equals(3);
      check(
        rules.map((r) => (r as Map)['type']),
      ).deepEquals(['deletion', 'non_fast_forward', 'required_status_checks']);

      final params = (rules[2] as Map)['parameters'] as Map<String, dynamic>;
      check(params['strict_required_status_checks_policy']).equals(false);
      check(params['do_not_enforce_on_create']).equals(false);

      final checks = (params['required_status_checks'] as List)
          .cast<Map<String, dynamic>>();
      check(checks.map((c) => c['context']))
          .deepEquals(['analyze (dev)', 'markdown']);
      check(checks.last['integration_id']).equals(githubActionsAppId);
    });

    test('defaults missing bypass_actors rather than emitting null', () {
      final ruleset = sampleRuleset()..remove('bypass_actors');
      check(appendRequiredCheck(ruleset, 'markdown')!['bypass_actors'])
          .isA<List<dynamic>>()
          .isEmpty();
    });

    test('returns null when there is no status-check rule', () {
      final ruleset = sampleRuleset()
        ..['rules'] = [
          {'type': 'deletion'},
        ];
      check(appendRequiredCheck(ruleset, 'markdown')).isNull();
    });

    test('rulesetRequiresContext detects an existing context', () {
      check(rulesetRequiresContext(sampleRuleset(), 'analyze (dev)')).isTrue();
      check(rulesetRequiresContext(sampleRuleset(), 'markdown')).isFalse();
    });
  });

  group('rulesetTargetsBranch', () {
    Map<String, dynamic> ruleset({
      String target = 'branch',
      String enforcement = 'active',
      List<String> include = const ['~DEFAULT_BRANCH'],
      List<String> exclude = const [],
    }) => {
      'target': target,
      'enforcement': enforcement,
      'conditions': {
        'ref_name': {'include': include, 'exclude': exclude},
      },
    };

    test('matches the default branch by alias, glob, and explicit ref', () {
      check(rulesetTargetsBranch(ruleset(), 'main')).isTrue();
      check(rulesetTargetsBranch(ruleset(include: ['~ALL']), 'main')).isTrue();
      check(rulesetTargetsBranch(ruleset(include: ['refs/heads/main']), 'main'))
          .isTrue();
    });

    test('rejects rulesets that do not govern the default branch', () {
      check(
        rulesetTargetsBranch(
          ruleset(include: ['refs/heads/release/*']),
          'main',
        ),
      ).isFalse();
      check(rulesetTargetsBranch(ruleset(target: 'tag'), 'main')).isFalse();
      check(rulesetTargetsBranch(ruleset(enforcement: 'disabled'), 'main'))
          .isFalse();
      check(
        rulesetTargetsBranch(
          ruleset(include: ['~ALL'], exclude: ['refs/heads/main']),
          'main',
        ),
      ).isFalse();
    });
  });

  group('RepoAlignScanner targetDir and worktree support', () {
    test(
      'scans a sibling worktree directory and normalizes canonical repo name',
      () async {
        await d.dir('_stats-repo-align', [
          d.file(
            'pubspec.yaml',
            'name: stats\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n',
          ),
        ]).create();

        final worktreePath = '${d.sandbox}/_stats-repo-align';
        final scanner = RepoAlignScanner(
          baseDirPath: d.sandbox,
          queryGitHubApi: false,
        );
        final results = scanner.scanAll(targetDir: worktreePath);
        check(results).length.equals(1);
        check(results.first.name).equals('stats');
        check(results.first.path).equals(worktreePath);
      },
    );
  });
}

/// A minimally-aligned repo, so that any reported issue is attributable to the
/// markdown settings under test rather than unrelated drift.
RepoAlignmentStatus _markdownFixture({
  RepoKind kind = RepoKind.toolOrApp,
  bool hasPrettierRc = false,
  bool hasMarkdownWorkflow = false,
  bool hasPrettierIgnore = false,
  bool hasRulesetOrProtection = true,
  List<String> requiredChecks = const ['analyze (dev)'],
}) => RepoAlignmentStatus(
  name: 'md_repo',
  path: '/tmp/md_repo',
  kind: kind,
  isArchived: false,
  isFork: false,
  isPrivate: false,
  defaultBranch: 'main',
  hasPubspec: true,
  sdkConstraint: '^3.0.0',
  packageNames: ['md_repo'],
  hasAnalysisOptions: true,
  analysisInclude: 'package:dart_flutter_team_lints/analysis_options.yaml',
  strictCasts: true,
  strictInference: true,
  strictRawTypes: true,
  customLints: [],
  workflowFiles: ['ci.yml'],
  hasCi: false,
  hasLowerBound: true,
  hasCogComp: true,
  hasAutosubmit: true,
  hasDependabot: true,
  hasPublish: true,
  hasPrettierRc: hasPrettierRc,
  hasMarkdownWorkflow: hasMarkdownWorkflow,
  hasPrettierIgnore: hasPrettierIgnore,
  autoMergeAllowed: true,
  hasRulesetOrProtection: hasRulesetOrProtection,
  requiredChecks: requiredChecks,
  defaultBranchRulesetId: hasRulesetOrProtection ? '123' : null,
  defaultBranchRequiredChecks: requiredChecks,
);
