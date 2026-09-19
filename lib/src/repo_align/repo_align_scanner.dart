import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../shared/analysis_options_resolver.dart';
import 'models.dart';

/// Known legacy or non-code repositories to ignore/mark legacy.
const Set<String> legacyOrIgnoredRepos = {
  'wynette',
  'kevmoo_legacy',
  'lint_cleanup',
  'vday_elle',
  'j832',
  'default_git_branch',
  'personal_dotfiles',
  'personal_knowledge',
  'dart-sdk-agent-config',
  'graf',
  'kevmoo.github.io',
  'dart_in_the_shell',
  'holdings',
  'json_compare_bench',
};

/// Known published packages on pub.dev.
const Set<String> publishedPackages = {
  'bench_press',
  'build_cli',
  'build_verify',
  'build_version',
  'completion',
  'completion.dart',
  'dhttpd',
  'git',
  'peanut',
  'peanut.dart',
  'pubviz',
  'qr',
  'qr.dart',
  'source_gen_test',
  'stats',
};

class RepoAlignScanner {
  final String baseDirPath;
  final bool queryGitHubApi;

  new({
    this.baseDirPath = '/usr/local/google/home/kevmoo/github/kevmoo',
    this.queryGitHubApi = true,
  });

  List<RepoAlignmentStatus> scanAll({String? targetRepo}) {
    final baseDir = Directory(baseDirPath);
    if (!baseDir.existsSync()) {
      throw FileSystemException('Base directory does not exist', baseDirPath);
    }

    final entries = baseDir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final results = <RepoAlignmentStatus>[];

    for (final dir in entries) {
      final name = p.basename(dir.path);
      if (name.startsWith('.') || name.startsWith('_')) continue;
      if (targetRepo != null && name != targetRepo) continue;

      final gitDir = Directory(p.join(dir.path, '.git'));
      final gitFile = File(p.join(dir.path, '.git'));
      if (!gitDir.existsSync() && !gitFile.existsSync()) continue;

      results.add(scanSingleRepo(dir));
    }

    return results;
  }

  RepoAlignmentStatus scanSingleRepo(Directory dir) {
    final name = p.basename(dir.path);
    final pubInfo = _scanPubspec(dir);
    final kind = _determineKind(name, pubInfo);
    final analysis = _scanAnalysisOptions(dir);
    final workflows = _scanWorkflows(dir);
    final dependabot = _scanDependabot(dir);
    final markdown = _scanMarkdownConfig(dir);
    final ghInfo = queryGitHubApi
        ? _scanGitHubRemote(name)
        : _defaultGitHubInfo();

    return RepoAlignmentStatus(
      name: name,
      path: dir.path,
      kind: kind,
      isArchived: ghInfo.isArchived,
      isFork: ghInfo.isFork,
      isPrivate: ghInfo.isPrivate,
      defaultBranch: ghInfo.defaultBranch,
      hasPubspec: pubInfo.hasPubspec,
      sdkConstraint: pubInfo.sdkConstraint,
      packageNames: pubInfo.packageNames,
      hasAnalysisOptions: analysis.hasAnalysisOptions,
      analysisInclude: analysis.analysisInclude,
      strictCasts: analysis.strictCasts,
      strictInference: analysis.strictInference,
      strictRawTypes: analysis.strictRawTypes,
      customLints: analysis.customLints,
      workflowFiles: workflows.files,
      hasCi: workflows.hasCi,
      hasLowerBound: workflows.hasLowerBound,
      hasCogComp: workflows.hasCogComp,
      hasAutosubmit: workflows.hasAutosubmit,
      hasDependabot: dependabot.hasDependabot,
      hasCanonicalDependabot: dependabot.hasCanonicalDependabot,
      hasDeprecatedAnalyticaRef: workflows.hasDeprecatedAnalyticaRef,
      hasNarrowWorkflowsPathFilter: workflows.hasNarrowWorkflowsPathFilter,
      hasPublish: workflows.hasPublish,
      hasHealth: workflows.hasHealth,
      hasPostSummaries: workflows.hasPostSummaries,
      expectedCiCheckPrefixes: workflows.expectedCiCheckPrefixes,
      hasPrettierRc: markdown.hasPrettierRc,
      hasMarkdownWorkflow: markdown.hasMarkdownWorkflow,
      hasPrettierIgnore: markdown.hasPrettierIgnore,
      autoMergeAllowed: ghInfo.autoMergeAllowed,
      hasAutosubmitLabel: ghInfo.hasAutosubmitLabel,
      hasRulesetOrProtection: ghInfo.hasRulesetOrProtection,
      requiredChecks: ghInfo.requiredChecks,
      defaultBranchRulesetId: ghInfo.defaultBranchRulesetId,
      defaultBranchRequiredChecks: ghInfo.defaultBranchRequiredChecks,
    );
  }

  _PubspecInfo _scanPubspec(Directory dir) {
    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      return (
        hasPubspec: false,
        sdkConstraint: null,
        isWorkspace: false,
        packageNames: <String>[],
      );
    }

    String? sdkConstraint;
    var isWorkspace = false;
    final packageNames = <String>[];

    try {
      final doc = loadYaml(pubspecFile.readAsStringSync());
      if (doc is YamlMap) {
        if (doc['name'] != null) packageNames.add(doc['name'].toString());
        if (doc['workspace'] != null) isWorkspace = true;
        final env = doc['environment'];
        if (env is YamlMap && env['sdk'] != null) {
          sdkConstraint = env['sdk'].toString();
        }
      }
    } catch (_) {}

    _scanPackagesDir(dir, packageNames);

    return (
      hasPubspec: true,
      sdkConstraint: sdkConstraint,
      isWorkspace: isWorkspace,
      packageNames: packageNames,
    );
  }

  void _scanPackagesDir(Directory dir, List<String> packageNames) {
    final pkgsDir = Directory(p.join(dir.path, 'packages'));
    if (!pkgsDir.existsSync()) return;

    for (final sub in pkgsDir.listSync().whereType<Directory>()) {
      final subPub = File(p.join(sub.path, 'pubspec.yaml'));
      if (!subPub.existsSync()) continue;
      try {
        final doc = loadYaml(subPub.readAsStringSync());
        if (doc is YamlMap && doc['name'] != null) {
          packageNames.add(doc['name'].toString());
        }
      } catch (_) {}
    }
  }

  RepoKind _determineKind(String name, _PubspecInfo pub) {
    if (legacyOrIgnoredRepos.contains(name)) {
      return RepoKind.legacyOrIgnored;
    }
    if (name == 'dash_skills' || name == 'kevmoo_skills') {
      return RepoKind.agentSkills;
    }
    if (publishedPackages.contains(name) ||
        (pub.hasPubspec && pub.packageNames.any(publishedPackages.contains))) {
      return RepoKind.publishedPackage;
    }
    if (pub.isWorkspace || name == 'analytica.dart' || name == 'dtt') {
      return RepoKind.monorepoWorkspace;
    }
    if (name == 'scripts.dart' ||
        name == 'slide_puzzle' ||
        name == 'kevmoo.com' ||
        name == 'flutter_web_cache_check') {
      return RepoKind.toolOrApp;
    }
    return RepoKind.experimentalOrPrototype;
  }

  _AnalysisInfo _scanAnalysisOptions(Directory dir) {
    final analysisFile = File(p.join(dir.path, 'analysis_options.yaml'));
    if (!analysisFile.existsSync()) {
      return (
        hasAnalysisOptions: false,
        analysisInclude: null,
        strictCasts: false,
        strictInference: false,
        strictRawTypes: false,
        customLints: <String>[],
      );
    }

    String? analysisInclude;
    try {
      final doc = loadYaml(analysisFile.readAsStringSync());
      if (doc is YamlMap && doc['include'] != null) {
        analysisInclude = doc['include'].toString();
      }
    } catch (_) {}

    final resolver = AnalysisOptionsResolver.createSync(
      packageDirectory: dir,
      fallbackDirectory: Directory(baseDirPath),
    );
    final resolved = resolver.resolveFromFile(analysisFile.path);

    final allLang = resolved.allLanguage;
    final strictCasts = allLang['strict-casts'] == true;
    final strictInference = allLang['strict-inference'] == true;
    final strictRawTypes = allLang['strict-raw-types'] == true;

    return (
      hasAnalysisOptions: true,
      analysisInclude: analysisInclude,
      strictCasts: strictCasts,
      strictInference: strictInference,
      strictRawTypes: strictRawTypes,
      customLints: resolved.explicitLints.toList()..sort(),
    );
  }

  _MarkdownInfo _scanMarkdownConfig(Directory dir) {
    final workflows = p.join(dir.path, '.github', 'workflows');
    // Both extensions, like every other detector here. Missing the `.yaml`
    // spelling would not just false-report "missing" -- `fix` would then write
    // a second workflow declaring the same `markdown` job ID, producing two
    // check runs competing for the context the ruleset matches on.
    final hasMarkdownWorkflow =
        File(p.join(workflows, 'markdown.yml')).existsSync() ||
        File(p.join(workflows, 'markdown.yaml')).existsSync();

    return (
      hasPrettierRc: File(p.join(dir.path, '.prettierrc.json')).existsSync(),
      hasMarkdownWorkflow: hasMarkdownWorkflow,
      hasPrettierIgnore: File(p.join(dir.path, '.prettierignore')).existsSync(),
    );
  }

  _WorkflowsInfo _scanWorkflows(Directory dir) {
    final workflowsDir = Directory(p.join(dir.path, '.github', 'workflows'));
    if (!workflowsDir.existsSync()) {
      return (
        files: <String>[],
        hasCi: false,
        hasLowerBound: false,
        hasCogComp: false,
        hasAutosubmit: false,
        hasPublish: false,
        hasHealth: false,
        hasPostSummaries: false,
        hasDeprecatedAnalyticaRef: false,
        hasNarrowWorkflowsPathFilter: false,
        expectedCiCheckPrefixes: <String>[],
      );
    }

    final inspected = workflowsDir
        .listSync()
        .whereType<File>()
        .map(_inspectWorkflowFile)
        .nonNulls
        .toList();

    return (
      files: inspected.map((w) => w.name).toList(),
      hasCi: inspected.any((w) => w.hasCi),
      hasLowerBound: inspected.any((w) => w.hasLowerBound),
      hasCogComp: inspected.any((w) => w.hasCogComp),
      hasAutosubmit: inspected.any((w) => w.hasAutosubmit),
      hasPublish: inspected.any((w) => w.hasPublish),
      hasHealth: inspected.any((w) => w.hasHealth),
      hasPostSummaries: inspected.any((w) => w.hasPostSummaries),
      hasDeprecatedAnalyticaRef: inspected.any(
        (w) => w.hasDeprecatedAnalyticaRef,
      ),
      hasNarrowWorkflowsPathFilter: inspected.any(
        (w) => w.hasNarrowWorkflowsPathFilter,
      ),
      expectedCiCheckPrefixes: inspected
          .expand((w) => w.expectedCiCheckPrefixes)
          .toList(),
    );
  }

  ({
    String name,
    bool hasCi,
    bool hasLowerBound,
    bool hasCogComp,
    bool hasAutosubmit,
    bool hasPublish,
    bool hasHealth,
    bool hasPostSummaries,
    bool hasDeprecatedAnalyticaRef,
    bool hasNarrowWorkflowsPathFilter,
    List<String> expectedCiCheckPrefixes,
  })?
  _inspectWorkflowFile(File wf) {
    final isYaml = wf.path.endsWith('.yml') || wf.path.endsWith('.yaml');
    if (!isYaml) return null;

    final name = p.basename(wf.path);
    final content = wf.readAsStringSync();

    final hasCi =
        name.contains('ci') ||
        name.contains('dart') ||
        name.contains('test') ||
        name.contains('validate');
    final hasLowerBound =
        content.contains('lower_bound') || content.contains('lower-bound');
    final hasCogComp =
        content.contains('cognitive_complexity') ||
        content.contains('cogcomp') ||
        content.contains('complexity');
    final hasAutosubmit =
        content.contains('autosubmit') || name.contains('autosubmit');
    final hasPublish =
        name.contains('publish') ||
        content.contains(
          'dart-lang/setup-dart/.github/workflows/publish.yml',
        ) ||
        content.contains('dart-lang/ecosystem/.github/workflows/publish.yaml');
    final hasHealth =
        name.contains('health') ||
        content.contains('dart-lang/ecosystem/.github/workflows/health.yaml');
    final hasPostSummaries =
        name.contains('post_summaries') ||
        name.contains('post-summaries') ||
        content.contains(
          'dart-lang/ecosystem/.github/workflows/post_summaries.yaml',
        );
    final hasDeprecatedAnalyticaRef = RegExp(r'uses:\s*kevmoo/analytica\.dart@')
        .hasMatch(content);
    final hasNarrowWorkflowsPathFilter =
        content.contains('.github/workflows/**') &&
        !content.contains("'.github/**'") &&
        !content.contains('".github/**"');

    final isCiWorkflow =
        hasCi &&
        !hasAutosubmit &&
        !hasPublish &&
        !hasHealth &&
        !hasPostSummaries;
    final expectedCiCheckPrefixes = _extractCiCheckPrefixes(
      content,
      isCiWorkflow: isCiWorkflow,
    );

    return (
      name: name,
      hasCi: hasCi,
      hasLowerBound: hasLowerBound,
      hasCogComp: hasCogComp,
      hasAutosubmit: hasAutosubmit,
      hasPublish: hasPublish,
      hasHealth: hasHealth,
      hasPostSummaries: hasPostSummaries,
      hasDeprecatedAnalyticaRef: hasDeprecatedAnalyticaRef,
      hasNarrowWorkflowsPathFilter: hasNarrowWorkflowsPathFilter,
      expectedCiCheckPrefixes: expectedCiCheckPrefixes,
    );
  }

  List<String> _extractCiCheckPrefixes(
    String content, {
    required bool isCiWorkflow,
  }) {
    if (!isCiWorkflow) return const [];
    try {
      final doc = loadYaml(content);
      final jobs = doc is YamlMap ? doc['jobs'] : null;
      if (jobs is! YamlMap) return const [];
      return jobs.entries
          .expand((e) => _extractJobPrefixes(e.key, e.value))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<String> _extractJobPrefixes(Object? jobKey, Object? jobVal) {
    if (jobVal is YamlMap) {
      final strategy = jobVal['strategy'];
      final matrix = strategy is YamlMap ? strategy['matrix'] : null;
      final matrixPkg = matrix is YamlMap ? matrix['package'] : null;
      if (matrixPkg is YamlList) {
        return matrixPkg.map((e) => e.toString()).toList();
      }
      final jobName = jobVal['name']?.toString();
      if (jobName != null && !jobName.contains(r'${{')) {
        return [jobName];
      }
    }
    return [jobKey.toString()];
  }

  ({bool hasDependabot, bool hasCanonicalDependabot}) _scanDependabot(
    Directory dir,
  ) {
    final d1 = File(p.join(dir.path, '.github', 'dependabot.yml'));
    final d2 = File(p.join(dir.path, '.github', 'dependabot.yaml'));
    final file = d1.existsSync() ? d1 : (d2.existsSync() ? d2 : null);
    if (file == null) {
      return (hasDependabot: false, hasCanonicalDependabot: false);
    }
    final content = file.readAsStringSync();
    final hasCanonical =
        content.contains('github-actions') &&
        content.contains('groups:') &&
        content.contains('autosubmit');
    return (hasDependabot: true, hasCanonicalDependabot: hasCanonical);
  }

  _GitHubInfo _defaultGitHubInfo() => (
    isArchived: false,
    isFork: false,
    isPrivate: false,
    defaultBranch: 'main',
    autoMergeAllowed: false,
    hasAutosubmitLabel: true,
    hasRulesetOrProtection: false,
    requiredChecks: <String>[],
    defaultBranchRulesetId: null,
    defaultBranchRequiredChecks: <String>[],
  );

  _GitHubInfo _scanGitHubRemote(String name) {
    var isArchived = false;
    var isFork = false;
    var isPrivate = false;
    var defaultBranch = 'main';
    var autoMergeAllowed = false;
    var hasAutosubmitLabel = false;
    var hasRulesetOrProtection = false;
    final requiredChecks = <String>[];
    var defaultBranchRequiredChecks = <String>[];
    String? defaultBranchRulesetId;

    try {
      final repoRes = Process.runSync('gh', ['api', 'repos/kevmoo/$name']);
      if (repoRes.exitCode == 0) {
        final repoJson =
            jsonDecode(repoRes.stdout.toString()) as Map<String, dynamic>;
        isArchived = repoJson['archived'] == true;
        isFork = repoJson['fork'] == true;
        isPrivate = repoJson['private'] == true;
        defaultBranch = repoJson['default_branch']?.toString() ?? 'main';
        autoMergeAllowed = repoJson['allow_auto_merge'] == true;
      }

      final labelRes = Process.runSync('gh', [
        'api',
        'repos/kevmoo/$name/labels/autosubmit',
      ]);
      hasAutosubmitLabel = labelRes.exitCode == 0;

      final rulesets = _scanRulesets(name, defaultBranch);
      hasRulesetOrProtection = rulesets.found;
      requiredChecks.addAll(rulesets.allChecks);
      defaultBranchRulesetId = rulesets.defaultBranchRulesetId;
      defaultBranchRequiredChecks = rulesets.defaultBranchChecks;

      if (!hasRulesetOrProtection) {
        // Legacy branch protection has no ruleset id, so it governs the
        // default branch by definition and cannot be written to by `fix`.
        final protectionChecks = <String>[];
        hasRulesetOrProtection = _scanBranchProtection(
          name,
          defaultBranch,
          protectionChecks,
        );
        requiredChecks.addAll(protectionChecks);
        defaultBranchRequiredChecks = protectionChecks;
      }
    } catch (_) {}

    return (
      isArchived: isArchived,
      isFork: isFork,
      isPrivate: isPrivate,
      defaultBranch: defaultBranch,
      autoMergeAllowed: autoMergeAllowed,
      hasAutosubmitLabel: hasAutosubmitLabel,
      hasRulesetOrProtection: hasRulesetOrProtection,
      requiredChecks: requiredChecks,
      defaultBranchRulesetId: defaultBranchRulesetId,
      defaultBranchRequiredChecks: defaultBranchRequiredChecks,
    );
  }

  /// Scans every ruleset, and separately identifies the one that actually
  /// governs [defaultBranch].
  ///
  /// The union across all rulesets is what the clamping and primary-CI checks
  /// want, but anything that *writes* needs to know which ruleset to write to
  /// and what that specific ruleset already requires.
  _RulesetScan _scanRulesets(String name, String defaultBranch) {
    const empty = (
      found: false,
      defaultBranchRulesetId: null,
      allChecks: <String>[],
      defaultBranchChecks: <String>[],
    );

    final res = Process.runSync('gh', [
      'api',
      'repos/kevmoo/$name/rulesets',
      '--jq',
      '.[].id',
    ]);
    if (res.exitCode != 0 || res.stdout.toString().trim().isEmpty) return empty;

    final allChecks = <String>[];
    final defaultBranchChecks = <String>[];
    String? defaultBranchRulesetId;

    for (final rawId in res.stdout.toString().trim().split('\n')) {
      final id = rawId.trim();
      if (id.isEmpty) continue;

      final json = _fetchSingleRuleset(name, id);
      if (json == null) continue;

      final checks = <String>[];
      for (final r in json['rules'] as List<dynamic>? ?? const []) {
        _extractRuleStatusChecks(r, checks);
      }
      allChecks.addAll(checks);

      if (defaultBranchRulesetId == null &&
          rulesetTargetsBranch(json, defaultBranch)) {
        defaultBranchRulesetId = id;
        defaultBranchChecks.addAll(checks);
      }
    }

    return (
      found: true,
      defaultBranchRulesetId: defaultBranchRulesetId,
      allChecks: allChecks,
      defaultBranchChecks: defaultBranchChecks,
    );
  }

  Map<String, dynamic>? _fetchSingleRuleset(String name, String id) {
    final detail = Process.runSync('gh', [
      'api',
      'repos/kevmoo/$name/rulesets/$id',
    ]);
    if (detail.exitCode != 0) return null;
    final json = jsonDecode(detail.stdout.toString());
    return json is Map<String, dynamic> ? json : null;
  }

  void _extractRuleStatusChecks(dynamic r, List<String> requiredChecks) {
    if (r is! Map || r['type'] != 'required_status_checks') return;
    final params = r['parameters'] as Map<String, dynamic>?;
    final scList = params?['required_status_checks'] as List<dynamic>?;
    if (scList == null) return;
    for (final sc in scList) {
      if (sc is Map && sc['context'] != null) {
        requiredChecks.add(sc['context'].toString());
      }
    }
  }

  bool _scanBranchProtection(
    String name,
    String defaultBranch,
    List<String> requiredChecks,
  ) {
    final res = Process.runSync('gh', [
      'api',
      'repos/kevmoo/$name/branches/$defaultBranch/protection',
    ]);
    if (res.exitCode != 0) return false;
    final json = jsonDecode(res.stdout.toString());
    if (json is! Map<String, dynamic>) return false;
    final rsc = json['required_status_checks'] as Map<String, dynamic>?;
    final contexts = rsc?['contexts'] as List<dynamic>?;
    if (contexts != null) {
      for (final c in contexts) {
        requiredChecks.add(c.toString());
      }
    }
    return true;
  }
}

typedef _PubspecInfo = ({
  bool hasPubspec,
  String? sdkConstraint,
  bool isWorkspace,
  List<String> packageNames,
});

typedef _AnalysisInfo = ({
  bool hasAnalysisOptions,
  String? analysisInclude,
  bool strictCasts,
  bool strictInference,
  bool strictRawTypes,
  List<String> customLints,
});

typedef _WorkflowsInfo = ({
  List<String> files,
  bool hasCi,
  bool hasLowerBound,
  bool hasCogComp,
  bool hasAutosubmit,
  bool hasPublish,
  bool hasHealth,
  bool hasPostSummaries,
  bool hasDeprecatedAnalyticaRef,
  bool hasNarrowWorkflowsPathFilter,
  List<String> expectedCiCheckPrefixes,
});

typedef _MarkdownInfo = ({
  bool hasPrettierRc,
  bool hasMarkdownWorkflow,
  bool hasPrettierIgnore,
});

typedef _RulesetScan = ({
  bool found,
  String? defaultBranchRulesetId,
  List<String> allChecks,
  List<String> defaultBranchChecks,
});

/// Whether [ruleset] actively governs [defaultBranch].
///
/// A repo can carry several branch rulesets (`release/*`, tag targets). Writing
/// a required check into the wrong one leaves the default branch ungated while
/// deadlocking some other branch pattern on a check that never runs there.
bool rulesetTargetsBranch(Map<String, dynamic> ruleset, String defaultBranch) {
  if (ruleset['target'] != 'branch') return false;
  if (ruleset['enforcement'] != 'active') return false;

  final conditions = ruleset['conditions'] as Map<String, dynamic>?;
  final refName = conditions?['ref_name'] as Map<String, dynamic>?;
  final include = refName?['include'] as List<dynamic>? ?? const [];
  final exclude = refName?['exclude'] as List<dynamic>? ?? const [];

  if (exclude.any((e) => e == 'refs/heads/$defaultBranch')) return false;

  return include.any(
    (i) =>
        i == '~DEFAULT_BRANCH' ||
        i == '~ALL' ||
        i == 'refs/heads/$defaultBranch',
  );
}

typedef _GitHubInfo = ({
  bool isArchived,
  bool isFork,
  bool isPrivate,
  String defaultBranch,
  bool autoMergeAllowed,
  bool hasAutosubmitLabel,
  bool hasRulesetOrProtection,
  List<String> requiredChecks,
  String? defaultBranchRulesetId,
  List<String> defaultBranchRequiredChecks,
});
