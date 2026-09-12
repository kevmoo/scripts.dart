import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import 'canonical_templates.dart';
import 'models.dart';
import 'repo_align_scanner.dart';

class RepoAlignRunner {
  final RepoAlignScanner scanner;

  new({RepoAlignScanner? scanner}) : scanner = scanner ?? RepoAlignScanner();

  void runCheck({String? targetRepo, bool jsonOutput = false}) {
    final results = scanner.scanAll(targetRepo: targetRepo);

    if (jsonOutput) {
      final jsonStr = const JsonEncoder.withIndent('  ')
          .convert(results.map((r) => r.toJson()).toList());
      print(jsonStr);
      return;
    }

    print('');
    print(styleBold.wrap('📊 kevmoo Repositories Alignment Audit Report'));
    print(
      'Scanned ${results.length} repositories under ${scanner.baseDirPath}\n',
    );

    final activeResults = results
        .where((r) => r.kind != RepoKind.legacyOrIgnored && !r.isArchived)
        .toList();
    final legacyResults = results
        .where((r) => r.kind == RepoKind.legacyOrIgnored || r.isArchived)
        .toList();

    _printSummaryTable(activeResults);
    _printIssues(activeResults);
    _printLegacySummary(legacyResults);
  }

  void _printSummaryTable(List<RepoAlignmentStatus> activeResults) {
    print('<!-- mdformat off(prevent table wrapping) -->');
    print(
      '| Repository | Kind | Strict Mode | Lower Bound | CogComp | '
      'Autosubmit | Dependabot | Auto-Merge | Status |',
    );
    print(
      '| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |',
    );

    for (final r in activeResults) {
      final strictIcon = _strictModeIcon(r);
      final lbIcon = _lowerBoundIcon(r);
      final ccIcon = _complexityIcon(r);
      final asIcon = r.hasAutosubmit ? '✅' : '❌';
      final dbIcon = r.hasDependabot ? '✅' : '❌';
      final amIcon = r.autoMergeAllowed ? '✅' : '❌';
      final status = r.isAligned
          ? '🟢 Aligned'
          : '🔴 ${r.issues.length} Drift(s)';

      final line =
          '| **`${r.name}`** | ${r.kind.name} | $strictIcon | $lbIcon | '
          '$ccIcon | $asIcon | $dbIcon | $amIcon | $status |';
      print(line);
    }
    print('<!-- mdformat on -->\n');
  }

  String _strictModeIcon(RepoAlignmentStatus r) {
    if (r.hasFullStrictMode) return '✅';
    if (r.strictCasts || r.strictInference || r.strictRawTypes) return '⚠️';
    return '❌';
  }

  String _lowerBoundIcon(RepoAlignmentStatus r) {
    if (r.hasLowerBound) return '✅';
    if (r.kind == RepoKind.publishedPackage) return '❌';
    return '-';
  }

  String _complexityIcon(RepoAlignmentStatus r) {
    if (r.hasCogComp) return '✅';
    if (r.kind == RepoKind.publishedPackage) return '❌';
    return '-';
  }

  void _printIssues(List<RepoAlignmentStatus> activeResults) {
    final drifted = activeResults.where((r) => !r.isAligned).toList();
    if (drifted.isEmpty) {
      print(
        green.wrap(
          '🎉 All active repositories are fully aligned with '
          'canonical standards!',
        ),
      );
      return;
    }

    print(
      styleBold.wrap(
        '⚠️ Identified Gaps & Alignment Issues (${drifted.length} repos):',
      ),
    );
    for (final r in drifted) {
      print('\n${cyan.wrap('📦 ${r.name}')} (${r.kind.name}):');
      for (final issue in r.issues) {
        print('  - 🔴 $issue');
      }
    }
  }

  void _printLegacySummary(List<RepoAlignmentStatus> legacyResults) {
    if (legacyResults.isEmpty) return;
    final names = legacyResults.map((r) => r.name).join(', ');
    final count = legacyResults.length;
    final msg = '📦 Legacy / Ignored Repositories ($count): $names';
    print('\n${styleDim.wrap(msg)}\n');
  }

  void runFix({
    String? targetRepo,
    bool fixLints = false,
    bool fixCi = false,
    bool fixGitHub = false,
    bool dryRun = false,
  }) {
    var shouldFixLints = fixLints;
    var shouldFixCi = fixCi;
    var shouldFixGitHub = fixGitHub;

    if (!shouldFixLints && !shouldFixCi && !shouldFixGitHub) {
      shouldFixLints = true;
      shouldFixCi = true;
      shouldFixGitHub = true;
    }

    final results = scanner.scanAll(targetRepo: targetRepo);
    final targets = results
        .where((r) => r.kind != RepoKind.legacyOrIgnored && !r.isArchived)
        .toList();

    print(
      styleBold.wrap(
        '🛠️ Running Alignment Remediation (${dryRun ? 'DRY-RUN' : 'LIVE'}):',
      ),
    );

    for (final r in targets) {
      _fixSingleRepo(
        r,
        fixLints: shouldFixLints,
        fixCi: shouldFixCi,
        fixGitHub: shouldFixGitHub,
        dryRun: dryRun,
      );
    }

    print('\n${green.wrap('✅ Remediation pass completed.')}\n');
  }

  void _fixSingleRepo(
    RepoAlignmentStatus r, {
    required bool fixLints,
    required bool fixCi,
    required bool fixGitHub,
    required bool dryRun,
  }) {
    print('\nProcessing ${cyan.wrap(r.name)} (${r.kind.name})...');
    if (fixLints) _fixAnalysisOptions(r, dryRun: dryRun);
    if (fixCi) _fixCiWorkflows(r, dryRun: dryRun);
    if (fixGitHub) _fixGitHubSettings(r, dryRun: dryRun);
  }

  void _fixAnalysisOptions(RepoAlignmentStatus r, {required bool dryRun}) {
    if (!r.hasPubspec || r.kind == RepoKind.agentSkills) return;

    final analysisFile = File(p.join(r.path, 'analysis_options.yaml'));
    if (r.hasAnalysisOptions &&
        r.hasFullStrictMode &&
        r.analysisInclude ==
            'package:dart_flutter_team_lints/analysis_options.yaml') {
      return;
    }

    final action = dryRun ? 'Would update' : 'Updating';
    print('  📝 $action analysis_options.yaml to canonical standard');
    if (!dryRun) {
      analysisFile.writeAsStringSync(canonicalAnalysisOptions);
    }
  }

  void _fixCiWorkflows(RepoAlignmentStatus r, {required bool dryRun}) {
    final workflowsDir = Directory(p.join(r.path, '.github', 'workflows'));
    if (!workflowsDir.existsSync() && !dryRun) {
      workflowsDir.createSync(recursive: true);
    }

    _fixLowerBound(r, workflowsDir, dryRun: dryRun);
    _fixComplexity(r, workflowsDir, dryRun: dryRun);
    _fixAutosubmit(r, workflowsDir, dryRun: dryRun);
    _fixDependabot(r, dryRun: dryRun);
    _fixMarkdown(r, workflowsDir, dryRun: dryRun);
  }

  /// Markdown standardization applies to every repo kind -- there is no
  /// eligibility gate here, unlike the Dart-specific workflows.
  void _fixMarkdown(
    RepoAlignmentStatus r,
    Directory workflowsDir, {
    required bool dryRun,
  }) {
    if (!r.hasPrettierRc) {
      print('  📝 ${dryRun ? 'Would create' : 'Creating'} .prettierrc.json');
      if (!dryRun) {
        File(p.join(r.path, '.prettierrc.json'))
            .writeAsStringSync(canonicalPrettierRc);
      }
    }

    if (!r.hasMarkdownWorkflow) {
      print(
        '  🚀 ${dryRun ? 'Would create' : 'Creating'} .github/workflows/markdown.yml',
      );
      if (!dryRun) {
        File(p.join(workflowsDir.path, 'markdown.yml'))
            .writeAsStringSync(canonicalMarkdownWorkflow);
      }
    }

    if (r.hasPrettierIgnore) {
      print('  🧹 ${dryRun ? 'Would delete' : 'Deleting'} .prettierignore');
      if (!dryRun) File(p.join(r.path, '.prettierignore')).deleteSync();
    }
  }

  void _fixLowerBound(
    RepoAlignmentStatus r,
    Directory workflowsDir, {
    required bool dryRun,
  }) {
    if (r.kind != RepoKind.publishedPackage || r.hasLowerBound) return;
    final lbFile = File(p.join(workflowsDir.path, 'lower_bound.yml'));
    print(
      '  🚀 ${dryRun ? 'Would create' : 'Creating'} .github/workflows/lower_bound.yml',
    );
    if (!dryRun) lbFile.writeAsStringSync(canonicalLowerBoundWorkflow);
  }

  void _fixComplexity(
    RepoAlignmentStatus r,
    Directory workflowsDir, {
    required bool dryRun,
  }) {
    final eligible =
        r.kind == RepoKind.publishedPackage || r.kind == RepoKind.toolOrApp;
    if (!eligible || r.hasCogComp) return;
    final ccFile = File(p.join(workflowsDir.path, 'complexity.yml'));
    print(
      '  🚀 ${dryRun ? 'Would create' : 'Creating'} .github/workflows/complexity.yml',
    );
    if (!dryRun) ccFile.writeAsStringSync(canonicalComplexityWorkflow);
  }

  void _fixAutosubmit(
    RepoAlignmentStatus r,
    Directory workflowsDir, {
    required bool dryRun,
  }) {
    if (r.hasAutosubmit || r.kind == RepoKind.agentSkills) return;
    final asFile = File(p.join(workflowsDir.path, 'autosubmit.yml'));
    print(
      '  🚀 ${dryRun ? 'Would create' : 'Creating'} .github/workflows/autosubmit.yml',
    );
    if (!dryRun) asFile.writeAsStringSync(canonicalAutosubmitWorkflow);
  }

  void _fixDependabot(RepoAlignmentStatus r, {required bool dryRun}) {
    if (r.hasDependabot || r.kind == RepoKind.agentSkills) return;
    final dbFile = File(p.join(r.path, '.github', 'dependabot.yml'));
    print(
      '  🤖 ${dryRun ? 'Would create' : 'Creating'} .github/dependabot.yml',
    );
    if (!dryRun) {
      dbFile.parent.createSync(recursive: true);
      dbFile.writeAsStringSync(canonicalDependabotConfig);
    }
  }

  void _fixGitHubSettings(RepoAlignmentStatus r, {required bool dryRun}) {
    // Markdown gating runs for every kind. agentSkills repos are exempt from
    // the Dart-oriented settings below, but they do have branch rulesets and
    // they are the most markdown-heavy repos in the fleet.
    _fixMarkdownRequiredCheck(r, dryRun: dryRun);

    if (r.kind == RepoKind.agentSkills) return;
    _fixAutoMerge(r, dryRun: dryRun);
  }

  void _fixAutoMerge(RepoAlignmentStatus r, {required bool dryRun}) {
    if (r.autoMergeAllowed) return;
    print(
      '  🌐 ${dryRun ? 'Would enable' : 'Enabling'} auto-merge on '
      'GitHub (kevmoo/${r.name})',
    );
    if (!dryRun) {
      Process.runSync('gh', [
        'repo',
        'edit',
        'kevmoo/${r.name}',
        '--enable-auto-merge',
      ]);
    }
  }

  /// Appends [markdownCheckContext] to the default-branch ruleset's required
  /// status checks. A check that runs but does not gate is decoration.
  ///
  /// The rulesets API cannot PATCH-merge `required_status_checks`, so the whole
  /// `rules` array has to be read, amended, and PUT back.
  void _fixMarkdownRequiredCheck(
    RepoAlignmentStatus r, {
    required bool dryRun,
  }) {
    if (!r.hasMarkdownWorkflow) return;
    if (r.defaultBranchRequiredChecks.contains(markdownCheckContext)) return;

    print(
      '  🔒 ${dryRun ? 'Would require' : 'Requiring'} '
      '"$markdownCheckContext" check on ${r.defaultBranch}',
    );
    if (dryRun) return;

    final rulesetId = r.defaultBranchRulesetId;
    if (rulesetId == null) {
      print('  ${red.wrap('⚠️  No writable ruleset on ${r.defaultBranch}')}');
      return;
    }

    final read = Process.runSync('gh', [
      'api',
      'repos/kevmoo/${r.name}/rulesets/$rulesetId',
    ]);
    if (read.exitCode != 0) {
      print('  ${red.wrap('⚠️  Failed to read ruleset $rulesetId')}');
      return;
    }

    final ruleset = jsonDecode(read.stdout as String) as Map<String, dynamic>;

    // The scan happens up to ~30 repos before this write, so re-check against
    // what the ruleset says right now rather than trusting the stale snapshot.
    if (rulesetRequiresContext(ruleset, markdownCheckContext)) {
      print('  ✓ Already required (added since scan)');
      return;
    }

    final payload = appendRequiredCheck(ruleset, markdownCheckContext);
    if (payload == null) {
      print('  ${red.wrap('⚠️  Ruleset has no required_status_checks rule')}');
      return;
    }

    final tmpDir = Directory.systemTemp.createTempSync('repo_align_');
    try {
      final tmp = File(p.join(tmpDir.path, 'ruleset.json'))
        ..writeAsStringSync(jsonEncode(payload));
      final write = Process.runSync('gh', [
        'api',
        '--method',
        'PUT',
        'repos/kevmoo/${r.name}/rulesets/$rulesetId',
        '--input',
        tmp.path,
      ]);
      if (write.exitCode != 0) {
        print('  ${red.wrap('⚠️  Failed to update ruleset: ${write.stderr}')}');
      }
    } finally {
      tmpDir.deleteSync(recursive: true);
    }
  }
}

/// Whether [ruleset] already requires [context].
bool rulesetRequiresContext(Map<String, dynamic> ruleset, String context) {
  final rules = ruleset['rules'] as List<dynamic>? ?? const [];
  for (final rule in rules) {
    if (rule is! Map || rule['type'] != 'required_status_checks') continue;
    final params = rule['parameters'] as Map<String, dynamic>?;
    final checks =
        params?['required_status_checks'] as List<dynamic>? ?? const [];
    if (checks.any((c) => c is Map && c['context'] == context)) return true;
  }
  return false;
}

/// Builds the ruleset PUT payload with [context] appended, or `null` if the
/// ruleset has no `required_status_checks` rule to append to.
///
/// Only the writable subset of the ruleset is forwarded; `id`, `source`,
/// `created_at`, `_links` and friends are server-owned. The rule parameters are
/// mutated in place so sibling rules and untouched parameters ride along
/// unchanged.
Map<String, dynamic>? appendRequiredCheck(
  Map<String, dynamic> ruleset,
  String context,
) {
  final rules = (ruleset['rules'] as List).cast<Map<String, dynamic>>();
  final target = rules.firstWhereOrNull(
    (Map<String, dynamic> rule) => rule['type'] == 'required_status_checks',
  );
  if (target == null) return null;

  final params = target['parameters'] as Map<String, dynamic>;
  final checks = (params['required_status_checks'] as List).toList()
    ..add({'context': context, 'integration_id': githubActionsAppId});
  params['required_status_checks'] = checks;

  return {
    'name': ruleset['name'],
    'target': ruleset['target'],
    'enforcement': ruleset['enforcement'],
    'bypass_actors': ruleset['bypass_actors'] ?? <dynamic>[],
    'conditions': ruleset['conditions'],
    'rules': rules,
  };
}

/// The GitHub App id for GitHub Actions. Pinning `integration_id` stops a
/// third-party app from satisfying a required check.
const int githubActionsAppId = 15368;
