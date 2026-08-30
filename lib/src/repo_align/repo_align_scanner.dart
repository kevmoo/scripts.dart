import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

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
};

/// Known published packages on pub.dev.
const Set<String> publishedPackages = {
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
      hasDependabot: dependabot,
      hasPublish: workflows.hasPublish,
      autoMergeAllowed: ghInfo.autoMergeAllowed,
      hasRulesetOrProtection: ghInfo.hasRulesetOrProtection,
      requiredChecks: ghInfo.requiredChecks,
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
    if (pub.isWorkspace || name == 'analytica.dart' || name == 'dtt') {
      return RepoKind.monorepoWorkspace;
    }
    if (publishedPackages.contains(name) ||
        (pub.hasPubspec && pub.packageNames.any(publishedPackages.contains))) {
      return RepoKind.publishedPackage;
    }
    if (name == 'scripts.dart' ||
        name == 'slide_puzzle' ||
        name == 'kevmoo.com') {
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
    var strictCasts = false;
    var strictInference = false;
    var strictRawTypes = false;
    final customLints = <String>[];

    try {
      final doc = loadYaml(analysisFile.readAsStringSync());
      if (doc is YamlMap) {
        if (doc['include'] != null) analysisInclude = doc['include'].toString();
        final analyzer = doc['analyzer'];
        if (analyzer is YamlMap) {
          final lang = analyzer['language'];
          if (lang is YamlMap) {
            strictCasts = lang['strict-casts'] == true;
            strictInference = lang['strict-inference'] == true;
            strictRawTypes = lang['strict-raw-types'] == true;
          }
        }
        _parseLinterRules(doc['linter'], customLints);
      }
    } catch (_) {}

    return (
      hasAnalysisOptions: true,
      analysisInclude: analysisInclude,
      strictCasts: strictCasts,
      strictInference: strictInference,
      strictRawTypes: strictRawTypes,
      customLints: customLints,
    );
  }

  void _parseLinterRules(dynamic linter, List<String> customLints) {
    if (linter is! YamlMap) return;
    final rules = linter['rules'];
    if (rules is YamlList) {
      for (final r in rules) {
        customLints.add(r.toString());
      }
    } else if (rules is YamlMap) {
      for (final entry in rules.entries) {
        customLints.add(entry.value == true ? '${entry.key}' : '!${entry.key}');
      }
    }
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
      );
    }

    final files = <String>[];
    var hasCi = false;
    var hasLowerBound = false;
    var hasCogComp = false;
    var hasAutosubmit = false;
    var hasPublish = false;

    for (final wf in workflowsDir.listSync().whereType<File>()) {
      final res = _inspectWorkflowFile(wf);
      if (res == null) continue;
      files.add(res.name);
      if (res.hasCi) hasCi = true;
      if (res.hasLowerBound) hasLowerBound = true;
      if (res.hasCogComp) hasCogComp = true;
      if (res.hasAutosubmit) hasAutosubmit = true;
      if (res.hasPublish) hasPublish = true;
    }

    return (
      files: files,
      hasCi: hasCi,
      hasLowerBound: hasLowerBound,
      hasCogComp: hasCogComp,
      hasAutosubmit: hasAutosubmit,
      hasPublish: hasPublish,
    );
  }

  ({
    String name,
    bool hasCi,
    bool hasLowerBound,
    bool hasCogComp,
    bool hasAutosubmit,
    bool hasPublish,
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
        content.contains('dart-lang/setup-dart/.github/workflows/publish.yml');

    return (
      name: name,
      hasCi: hasCi,
      hasLowerBound: hasLowerBound,
      hasCogComp: hasCogComp,
      hasAutosubmit: hasAutosubmit,
      hasPublish: hasPublish,
    );
  }

  bool _scanDependabot(Directory dir) {
    final d1 = File(p.join(dir.path, '.github', 'dependabot.yml'));
    final d2 = File(p.join(dir.path, '.github', 'dependabot.yaml'));
    return d1.existsSync() || d2.existsSync();
  }

  _GitHubInfo _defaultGitHubInfo() => (
    isArchived: false,
    isFork: false,
    isPrivate: false,
    defaultBranch: 'main',
    autoMergeAllowed: false,
    hasRulesetOrProtection: false,
    requiredChecks: <String>[],
  );

  _GitHubInfo _scanGitHubRemote(String name) {
    var isArchived = false;
    var isFork = false;
    var isPrivate = false;
    var defaultBranch = 'main';
    var autoMergeAllowed = false;
    var hasRulesetOrProtection = false;
    final requiredChecks = <String>[];

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

      hasRulesetOrProtection = _scanRulesets(name, requiredChecks);
      if (!hasRulesetOrProtection) {
        hasRulesetOrProtection = _scanBranchProtection(
          name,
          defaultBranch,
          requiredChecks,
        );
      }
    } catch (_) {}

    return (
      isArchived: isArchived,
      isFork: isFork,
      isPrivate: isPrivate,
      defaultBranch: defaultBranch,
      autoMergeAllowed: autoMergeAllowed,
      hasRulesetOrProtection: hasRulesetOrProtection,
      requiredChecks: requiredChecks,
    );
  }

  bool _scanRulesets(String name, List<String> requiredChecks) {
    final res = Process.runSync('gh', [
      'api',
      'repos/kevmoo/$name/rulesets',
      '--jq',
      '.[].id',
    ]);
    if (res.exitCode != 0 || res.stdout.toString().trim().isEmpty) return false;

    final ids = res.stdout.toString().trim().split('\n');
    for (final id in ids) {
      if (id.trim().isEmpty) continue;
      _fetchSingleRuleset(name, id.trim(), requiredChecks);
    }
    return true;
  }

  void _fetchSingleRuleset(
    String name,
    String id,
    List<String> requiredChecks,
  ) {
    final detail = Process.runSync('gh', [
      'api',
      'repos/kevmoo/$name/rulesets/$id',
    ]);
    if (detail.exitCode != 0) return;
    final json = jsonDecode(detail.stdout.toString());
    if (json is! Map<String, dynamic>) return;
    final rules = json['rules'] as List<dynamic>? ?? [];
    for (final r in rules) {
      _extractRuleStatusChecks(r, requiredChecks);
    }
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
});

typedef _GitHubInfo = ({
  bool isArchived,
  bool isFork,
  bool isPrivate,
  String defaultBranch,
  bool autoMergeAllowed,
  bool hasRulesetOrProtection,
  List<String> requiredChecks,
});
