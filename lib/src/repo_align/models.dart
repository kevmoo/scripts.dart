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

  // GitHub Remote Configuration
  final bool autoMergeAllowed;
  final bool hasRulesetOrProtection;
  final List<String> requiredChecks;

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
    required this.autoMergeAllowed,
    required this.hasRulesetOrProtection,
    required this.requiredChecks,
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

  void _checkCiIssues(List<String> result) {
    if (kind == RepoKind.publishedPackage) {
      if (!hasLowerBound) result.add('Missing lower_bound.yml');
      if (!hasCogComp) result.add('Missing complexity.yml');
      if (!hasAutosubmit) result.add('Missing autosubmit.yml');
      if (!hasDependabot) result.add('Missing .github/dependabot.yml');
      return;
    }

    if (kind == RepoKind.monorepoWorkspace || kind == RepoKind.toolOrApp) {
      if (!hasAutosubmit) result.add('Missing autosubmit.yml');
      if (!hasDependabot) result.add('Missing .github/dependabot.yml');
    }
  }

  void _checkGitHubIssues(List<String> result) {
    if (kind == RepoKind.agentSkills) return;

    if (!autoMergeAllowed) {
      result.add('Auto-merge not enabled (allow_auto_merge = false)');
    }

    if (!hasRulesetOrProtection) {
      result.add('No branch protection or ruleset on $defaultBranch');
    } else if (requiredChecks.isEmpty) {
      result.add('Branch ruleset has 0 required status checks');
    } else {
      final unclamped = requiredChecks.where((c) => c.length > 100).toList();
      if (unclamped.isNotEmpty) {
        result.add(
          'Branch ruleset has ${unclamped.length} required check(s) >100 chars '
          '(will fail to match truncated GHA check names)',
        );
      }
    }
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
    'autoMergeAllowed': autoMergeAllowed,
    'hasRulesetOrProtection': hasRulesetOrProtection,
    'requiredChecks': requiredChecks,
    'issues': issues,
    'isAligned': isAligned,
  };
}

/// Clamps a GitHub Actions check run name to 100 characters to match the
/// GitHub Checks API truncation limit (100 chars with `...`).
String clampGhaCheckName(String name) {
  if (name.length <= 100) return name;
  return '${name.substring(0, 97)}...';
}
