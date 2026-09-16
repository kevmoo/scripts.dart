import 'canonical_templates.dart';

/// Classification of a personal GitHub repository.
enum RepoKind {
  publishedPackage,
  monorepoWorkspace,
  toolOrApp,
  agentSkills,
  experimentalOrPrototype,
  legacyOrIgnored,
}

/// Information about a discovered repository's alignment status.
class RepoAlignmentStatus {
  final String name;
  final String path;
  final RepoKind kind;
  final bool isArchived;
  final bool isFork;
  final bool isPrivate;
  final String defaultBranch;

  // Pubspec & Dart
  final bool hasPubspec;
  final String? sdkConstraint;
  final List<String> packageNames;

  // analysis_options.yaml
  final bool hasAnalysisOptions;
  final String? analysisInclude;
  final bool strictCasts;
  final bool strictInference;
  final bool strictRawTypes;
  final List<String> customLints;

  // CI Workflows
  final List<String> workflowFiles;
  final bool hasCi;
  final bool hasLowerBound;
  final bool hasCogComp;
  final bool hasAutosubmit;
  final bool hasDependabot;
  final bool hasPublish;
  final bool hasHealth;
  final bool hasPostSummaries;
  final List<String> expectedCiCheckPrefixes;

  // Markdown standardization
  final bool hasPrettierRc;
  final bool hasMarkdownWorkflow;
  final bool hasPrettierIgnore;

  // GitHub Remote Configuration
  final bool autoMergeAllowed;
  final bool hasRulesetOrProtection;

  /// Every required context, unioned across all rulesets.
  final List<String> requiredChecks;

  /// The ruleset that actually governs [defaultBranch], or `null` for legacy
  /// branch protection (which cannot be written to).
  final String? defaultBranchRulesetId;

  /// The contexts required by the default-branch ruleset alone. A context
  /// present only in some *other* ruleset does not gate the default branch.
  final List<String> defaultBranchRequiredChecks;

  new({
    required this.name,
    required this.path,
    required this.kind,
    required this.isArchived,
    required this.isFork,
    required this.isPrivate,
    required this.defaultBranch,
    required this.hasPubspec,
    required this.sdkConstraint,
    required this.packageNames,
    required this.hasAnalysisOptions,
    required this.analysisInclude,
    required this.strictCasts,
    required this.strictInference,
    required this.strictRawTypes,
    required this.customLints,
    required this.workflowFiles,
    required this.hasCi,
    required this.hasLowerBound,
    required this.hasCogComp,
    required this.hasAutosubmit,
    required this.hasDependabot,
    required this.hasPublish,
    this.hasHealth = false,
    this.hasPostSummaries = false,
    this.expectedCiCheckPrefixes = const [],
    this.hasPrettierRc = false,
    this.hasMarkdownWorkflow = false,
    this.hasPrettierIgnore = false,
    required this.autoMergeAllowed,
    required this.hasRulesetOrProtection,
    required this.requiredChecks,
    this.defaultBranchRulesetId,
    this.defaultBranchRequiredChecks = const [],
  });

  /// Check if the repo has full strict mode enabled.
  bool get hasFullStrictMode =>
      strictCasts && strictInference && strictRawTypes;

  /// Returns a list of identified alignment gaps/issues.
  List<String> get issues {
    if (kind == RepoKind.legacyOrIgnored || isArchived) return const [];

    final result = <String>[];
    _checkDartIssues(result);
    _checkCiIssues(result);
    _checkMarkdownIssues(result);
    _checkGitHubIssues(result);
    return result;
  }

  void _checkDartIssues(List<String> result) {
    if (!hasPubspec || kind == RepoKind.agentSkills) return;

    if (!hasAnalysisOptions) {
      result.add('Missing analysis_options.yaml');
      return;
    }

    if (analysisInclude !=
        'package:dart_flutter_team_lints/analysis_options.yaml') {
      result.add('Non-canonical include: $analysisInclude');
    }

    if (!hasFullStrictMode) {
      final missing = <String>[
        if (!strictCasts) 'strict-casts',
        if (!strictInference) 'strict-inference',
        if (!strictRawTypes) 'strict-raw-types',
      ];
      result.add('Incomplete strict mode (missing: ${missing.join(', ')})');
    }
  }

  /// Whether this repository kind requires standard Dart CI workflows
  /// (`complexity.yml`, `autosubmit.yml`, and `.github/dependabot.yml`).
  bool get requiresStandardCiWorkflows =>
      kind == RepoKind.publishedPackage ||
      kind == RepoKind.monorepoWorkspace ||
      kind == RepoKind.toolOrApp;

  void _checkCiIssues(List<String> result) {
    if (!requiresStandardCiWorkflows) return;
    if (kind == RepoKind.publishedPackage && !hasLowerBound) {
      result.add('Missing lower_bound.yml');
    }
    if (!hasCogComp) result.add('Missing complexity.yml');
    if (!hasAutosubmit) result.add('Missing autosubmit.yml');
    if (!hasDependabot) result.add('Missing .github/dependabot.yml');
  }

  /// Markdown standardization applies to *every* repo kind, including
  /// [RepoKind.agentSkills] -- skills repos are the most markdown-heavy of all,
  /// and they do carry branch rulesets.
  void _checkMarkdownIssues(List<String> result) {
    if (!hasPrettierRc) result.add('Missing .prettierrc.json');
    if (!hasMarkdownWorkflow) result.add('Missing markdown.yml');

    // `.prettierignore` was deliberately removed from every repo as
    // speculative noise; its reappearance is a regression, not a gap.
    if (hasPrettierIgnore) {
      result.add('Stray .prettierignore (should not exist)');
    }

    // A markdown check that runs but does not gate is decoration. This lives
    // here rather than in _checkGitHubIssues because that method exempts
    // agentSkills, and markdown gating must not be exempt.
    if (hasMarkdownWorkflow &&
        hasRulesetOrProtection &&
        !defaultBranchRequiredChecks.contains(markdownCheckContext)) {
      result.add('markdown.yml present but not a required check');
    }
  }

  void _checkGitHubIssues(List<String> result) {
    if (kind == RepoKind.agentSkills) return;

    if (!autoMergeAllowed) {
      result.add('Auto-merge not enabled (allow_auto_merge = false)');
    }

    if (!hasRulesetOrProtection) {
      result.add('No branch protection or ruleset on $defaultBranch');
      return;
    }

    if (requiredChecks.isEmpty) {
      final msg = autoMergeAllowed
          ? 'CRITICAL: Auto-merge enabled with 0 required status checks '
                '(ungated merging!)'
          : 'Branch ruleset has 0 required status checks';
      result.add(msg);
      return;
    }

    final unclamped = requiredChecks.where((c) => c.length > 100).toList();
    if (unclamped.isNotEmpty) {
      result.add(
        'Branch ruleset has ${unclamped.length} required check(s) >100 chars '
        '(will fail to match truncated GHA check names)',
      );
    }

    if (hasCi && !_hasPrimaryCiCheck) {
      final expectedStr = expectedCiCheckPrefixes.isNotEmpty
          ? expectedCiCheckPrefixes.join('/')
          : 'analyze/test/build/validate';
      result.add(
        'Branch ruleset missing primary CI check '
        '(expected: $expectedStr)',
      );
    }
  }

  bool get _hasPrimaryCiCheck {
    if (expectedCiCheckPrefixes.isEmpty) return true;
    return requiredChecks.any(
      (req) => expectedCiCheckPrefixes.any(
        (prefix) => req == prefix || req.startsWith(prefix),
      ),
    );
  }

  bool get isAligned => issues.isEmpty;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'kind': kind.name,
    'isArchived': isArchived,
    'isFork': isFork,
    'isPrivate': isPrivate,
    'defaultBranch': defaultBranch,
    'hasPubspec': hasPubspec,
    'sdkConstraint': sdkConstraint,
    'packageNames': packageNames,
    'hasAnalysisOptions': hasAnalysisOptions,
    'analysisInclude': analysisInclude,
    'strictCasts': strictCasts,
    'strictInference': strictInference,
    'strictRawTypes': strictRawTypes,
    'customLintsCount': customLints.length,
    'workflowFiles': workflowFiles,
    'hasCi': hasCi,
    'hasLowerBound': hasLowerBound,
    'hasCogComp': hasCogComp,
    'hasAutosubmit': hasAutosubmit,
    'hasDependabot': hasDependabot,
    'hasPublish': hasPublish,
    'hasPrettierRc': hasPrettierRc,
    'hasMarkdownWorkflow': hasMarkdownWorkflow,
    'hasPrettierIgnore': hasPrettierIgnore,
    'autoMergeAllowed': autoMergeAllowed,
    'hasRulesetOrProtection': hasRulesetOrProtection,
    'requiredChecks': requiredChecks,
    'defaultBranchRulesetId': defaultBranchRulesetId,
    'defaultBranchRequiredChecks': defaultBranchRequiredChecks,
    'issues': issues,
    'isAligned': isAligned,
  };
}
