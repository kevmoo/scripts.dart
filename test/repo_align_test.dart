import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/repo_align/canonical_templates.dart';
import 'package:kevmoo_scripts/src/repo_align/models.dart';
import 'package:kevmoo_scripts/src/repo_align/repo_align_runner.dart';
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
      // Regression: _checkGitHubIssues exempts agentSkills, which silently
      // exempted the markdown gate too. kevmoo_skills and dash_skills both
      // have active branch rulesets, so they must not be exempt.
      final status = _markdownFixture(
        kind: RepoKind.agentSkills,
        hasPrettierRc: true,
        hasMarkdownWorkflow: true,
        requiredChecks: ['validate'],
      );

      check(status.issues)
          .contains('markdown.yml present but not a required check');
    });

    test('does not flag gating when there is no ruleset at all', () {
      // Already reported as "No branch protection or ruleset"; a second
      // finding about gating would be noise.
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
    });

    test('prettier config is scoped to markdown only', () {
      check(canonicalPrettierRc).contains('"**/*.md"');
      check(canonicalPrettierRc).contains('"proseWrap": "always"');
      check(canonicalPrettierRc).contains('"printWidth": 80');
      check(canonicalPrettierRc)
          .contains('"embeddedLanguageFormatting": "off"');
    });

    test('markdown workflow job id matches the required check context', () {
      check(canonicalMarkdownWorkflow).contains('\n  $markdownCheckContext:\n');
    });

    test('markdown workflow pins prettier and has no paths filter', () {
      check(canonicalMarkdownWorkflow).contains('prettier@3.9.6');
      // A `paths:` filter on a required check deadlocks every PR that touches
      // no markdown. Match the indented YAML key, not the word in the comment.
      check(canonicalMarkdownWorkflow).not((it) => it.contains('\n    paths:'));
    });

    test('markdown workflow sha-pins its actions', () {
      check(
        canonicalMarkdownWorkflow,
      ).contains('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1');
      check(
        canonicalMarkdownWorkflow,
      ).contains('actions/setup-node@820762786026740c76f36085b0efc47a31fe5020');
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

  group('legacyOrIgnoredRepos', () {
    test('contains holdings and other known legacy repos', () {
      check(legacyOrIgnoredRepos).contains('holdings');
      check(legacyOrIgnoredRepos).contains('json_compare_bench');
      check(legacyOrIgnoredRepos).contains('wynette');
      check(legacyOrIgnoredRepos).contains('personal_dotfiles');
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

      // Server-owned fields must not be echoed back.
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
      // The failure this guards against: appending a required check to a
      // release ruleset leaves main ungated and deadlocks release branches.
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
