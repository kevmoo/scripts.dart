import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../process_utils.dart';
import '../repos_config.dart';
import '../shared/analysis_options_resolver.dart';
import '../shared/git_cli.dart';
import '../shared/spot_sync.dart';
import 'models.dart';
import 'repo_align_graphql.dart';
import 'workflow_matrix.dart';

class RepoAlignScanner {
  static String get defaultBaseDirPath => p.join(
    Platform.environment['HOME'] ?? Directory.current.path,
    'github',
    'kevmoo',
  );

  final String baseDirPath;
  final String owner;
  final bool queryGitHubApi;
  final RepoAlignConfig? portfolioConfig;
  final SyncProcessRunner processRunner;
  final ProcessRunner asyncProcessRunner;

  factory({
    String? baseDirPath,
    String? owner,
    bool queryGitHubApi = true,
    RepoAlignConfig? portfolioConfig,
    String? homeDirectory,
    SyncProcessRunner processRunner = defaultSyncProcessRunner,
    ProcessRunner asyncProcessRunner = defaultProcessRunner,
  }) {
    final resolvedConfig =
        portfolioConfig ??
        (baseDirPath == null
            ? loadRepoAlignConfig(homeDirectory: homeDirectory)
            : null);
    return ._(
      baseDirPath: baseDirPath ?? resolvedConfig?.baseDir ?? defaultBaseDirPath,
      owner: owner ?? resolvedConfig?.owner ?? 'kevmoo',
      queryGitHubApi: queryGitHubApi,
      portfolioConfig: resolvedConfig,
      processRunner: processRunner,
      asyncProcessRunner: asyncProcessRunner,
    );
  }

  const new _({
    required this.baseDirPath,
    required this.owner,
    required this.queryGitHubApi,
    required this.portfolioConfig,
    required this.processRunner,
    required this.asyncProcessRunner,
  });

  List<RepoAlignmentStatus> scanAll({String? targetRepo, String? targetDir}) =>
      scanPortfolio(targetRepo: targetRepo, targetDir: targetDir).repos;

  /// Asynchronous counterpart to [scanPortfolio] that executes all remote
  /// GitHub GraphQL batches concurrently.
  Future<RepoAlignScanReport> scanPortfolioAsync({
    String? targetRepo,
    String? targetDir,
  }) async {
    final config = portfolioConfig;
    if (targetDir == null && config != null && queryGitHubApi) {
      return _scanFromPortfolioConfigAsync(config, targetRepo: targetRepo);
    }
    return scanPortfolio(targetRepo: targetRepo, targetDir: targetDir);
  }

  Future<RepoAlignScanReport> _scanFromPortfolioConfigAsync(
    RepoAlignConfig config, {
    String? targetRepo,
  }) async {
    final canonicalSpotDefs = loadCanonicalSpotDefs();
    if (targetRepo != null) {
      final snapshots = await fetchRemoteRepoSnapshotsAsync(
        owner,
        [targetRepo],
        runner: asyncProcessRunner,
        targetsBranchPredicate: rulesetTargetsBranch,
      );
      return _assembleSingleTargetReport(
        targetRepo,
        snapshots[targetRepo],
        canonicalSpotDefs: canonicalSpotDefs,
      );
    }

    final activeNames = [...config.active]..sort();
    final snapshotsFuture = fetchRemoteRepoSnapshotsAsync(
      owner,
      activeNames,
      runner: asyncProcessRunner,
      targetsBranchPredicate: rulesetTargetsBranch,
    );
    final ownerReposFuture = fetchOwnerActiveCandidateReposAsync(
      owner,
      runner: asyncProcessRunner,
    );
    final snapshots = await snapshotsFuture;
    final ownerRepos = await ownerReposFuture;

    return _assemblePortfolioReport(
      config,
      activeNames: activeNames,
      snapshots: snapshots,
      ownerRepos: ownerRepos,
      canonicalSpotDefs: canonicalSpotDefs,
    );
  }

  /// Scans the configured portfolio (or local directory fallback when no
  /// `repos.yaml` is present) and reports both evaluated repositories and any
  /// unclassified non-fork, non-archived remote repositories.
  RepoAlignScanReport scanPortfolio({String? targetRepo, String? targetDir}) {
    if (targetDir != null) {
      final dir = Directory(targetDir);
      if (!dir.existsSync()) {
        throw FileSystemException('Target directory does not exist', targetDir);
      }
      return RepoAlignScanReport(
        repos: [scanSingleRepo(dir, repoNameOverride: targetRepo)],
      );
    }

    final config = portfolioConfig;
    if (config != null && queryGitHubApi) {
      return _scanFromPortfolioConfig(config, targetRepo: targetRepo);
    }

    return RepoAlignScanReport(
      repos: _scanLocalBaseDirectory(targetRepo: targetRepo),
    );
  }

  RepoAlignScanReport _scanFromPortfolioConfig(
    RepoAlignConfig config, {
    String? targetRepo,
  }) {
    final canonicalSpotDefs = loadCanonicalSpotDefs();
    if (targetRepo != null) {
      final snapshots = fetchRemoteRepoSnapshots(
        owner,
        [targetRepo],
        runner: processRunner,
        targetsBranchPredicate: rulesetTargetsBranch,
      );
      return _assembleSingleTargetReport(
        targetRepo,
        snapshots[targetRepo],
        canonicalSpotDefs: canonicalSpotDefs,
      );
    }

    final activeNames = [...config.active]..sort();
    final snapshots = fetchRemoteRepoSnapshots(
      owner,
      activeNames,
      runner: processRunner,
      targetsBranchPredicate: rulesetTargetsBranch,
    );
    final ownerRepos = fetchOwnerActiveCandidateRepos(
      owner,
      runner: processRunner,
    );
    return _assemblePortfolioReport(
      config,
      activeNames: activeNames,
      snapshots: snapshots,
      ownerRepos: ownerRepos,
      canonicalSpotDefs: canonicalSpotDefs,
    );
  }

  RepoAlignScanReport _assembleSingleTargetReport(
    String targetRepo,
    RemoteRepoSnapshot? snap, {
    required Map<String, String> canonicalSpotDefs,
  }) {
    if (snap != null) {
      return RepoAlignScanReport(
        repos: [
          _buildStatusFromRemoteSnapshot(
            snap,
            isExplicitlyIgnored: false,
            canonicalSpotDefs: canonicalSpotDefs,
          ),
        ],
      );
    }
    final localDir = Directory(p.join(baseDirPath, targetRepo));
    if (!localDir.existsSync()) return const RepoAlignScanReport(repos: []);
    return RepoAlignScanReport(repos: [scanSingleRepo(localDir)]);
  }

  RepoAlignScanReport _assemblePortfolioReport(
    RepoAlignConfig config, {
    required List<String> activeNames,
    required Map<String, RemoteRepoSnapshot> snapshots,
    required List<String> ownerRepos,
    required Map<String, String> canonicalSpotDefs,
  }) {
    final repos = <RepoAlignmentStatus>[];
    for (final name in activeNames) {
      final snap = snapshots[name];
      if (snap != null) {
        repos.add(
          _buildStatusFromRemoteSnapshot(
            snap,
            isExplicitlyIgnored: false,
            canonicalSpotDefs: canonicalSpotDefs,
          ),
        );
      } else {
        final localDir = Directory(p.join(baseDirPath, name));
        if (localDir.existsSync()) {
          repos.add(scanSingleRepo(localDir));
        }
      }
    }

    final known = {...config.active, ...config.ignore};
    final unclassified = ownerRepos.where((r) => !known.contains(r)).toList();
    return RepoAlignScanReport(repos: repos, unclassifiedRepos: unclassified);
  }

  List<RepoAlignmentStatus> _scanLocalBaseDirectory({String? targetRepo}) {
    final baseDir = Directory(baseDirPath);
    if (!baseDir.existsSync()) {
      throw FileSystemException('Base directory does not exist', baseDirPath);
    }

    final candidateDirs = _discoverCandidateLocalDirs(
      baseDir,
      targetRepo: targetRepo,
    );
    final names = candidateDirs.map((d) => p.basename(d.path)).toList();
    final snapshots = queryGitHubApi
        ? fetchRemoteRepoSnapshots(
            owner,
            names,
            runner: processRunner,
            targetsBranchPredicate: rulesetTargetsBranch,
          )
        : const <String, RemoteRepoSnapshot>{};

    final ignoreSet = portfolioConfig?.ignore.toSet() ?? const <String>{};
    final canonicalSpotDefs = loadCanonicalSpotDefs();
    return [
      for (final dir in candidateDirs)
        _scanLocalDirectoryWithOptionalRemote(
          dir,
          name: p.basename(dir.path),
          remote: snapshots[p.basename(dir.path)],
          isExplicitlyIgnored:
              targetRepo == null && ignoreSet.contains(p.basename(dir.path)),
          canonicalSpotDefs: canonicalSpotDefs,
        ),
    ];
  }

  List<Directory> _discoverCandidateLocalDirs(
    Directory baseDir, {
    required String? targetRepo,
  }) {
    final entries = baseDir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return entries
        .where((d) => _shouldScanLocalRepoDir(d, targetRepo: targetRepo))
        .toList();
  }

  bool _shouldScanLocalRepoDir(Directory dir, {required String? targetRepo}) {
    final name = p.basename(dir.path);
    if (name.startsWith('.') || name.startsWith('_')) return false;
    if (targetRepo != null) return name == targetRepo && _hasGitMetadata(dir);
    final config = portfolioConfig;
    if (config != null &&
        !config.active.contains(name) &&
        config.ignore.contains(name)) {
      return false;
    }
    return _hasGitMetadata(dir);
  }

  static bool _hasGitMetadata(Directory dir) =>
      Directory(p.join(dir.path, '.git')).existsSync() ||
      File(p.join(dir.path, '.git')).existsSync();

  static String _resolveCanonicalRepoName(
    Directory dir, {
    String? repoNameOverride,
  }) {
    if (repoNameOverride != null && repoNameOverride.trim().isNotEmpty) {
      return repoNameOverride.trim();
    }
    final rawName = p.basename(dir.path);
    if (!rawName.startsWith('_')) return rawName;

    final remoteUrl = defaultGitCli.stdoutOrNullSync(const [
      'remote',
      'get-url',
      'origin',
    ], workingDirectory: dir.path);
    if (remoteUrl != null) {
      final match = RegExp(r'[:/]([^/:]+?)(?:\.git)?$').firstMatch(remoteUrl);
      if (match != null) return match.group(1)!;
    }

    final withoutUnderscore = rawName.substring(1);
    final dashIdx = withoutUnderscore.indexOf('-');
    return dashIdx > 0
        ? withoutUnderscore.substring(0, dashIdx)
        : withoutUnderscore;
  }

  RepoAlignmentStatus scanSingleRepo(
    Directory dir, {
    String? repoNameOverride,
  }) {
    final name = _resolveCanonicalRepoName(
      dir,
      repoNameOverride: repoNameOverride,
    );
    final remote = queryGitHubApi
        ? fetchRemoteRepoSnapshots(
            owner,
            [name],
            runner: processRunner,
            targetsBranchPredicate: rulesetTargetsBranch,
          )[name]
        : null;
    final ignoreSet = portfolioConfig?.ignore.toSet() ?? const <String>{};
    return _scanLocalDirectoryWithOptionalRemote(
      dir,
      name: name,
      remote: remote,
      isExplicitlyIgnored: repoNameOverride == null && ignoreSet.contains(name),
      canonicalSpotDefs: loadCanonicalSpotDefs(),
    );
  }

  RepoAlignmentStatus _scanLocalDirectoryWithOptionalRemote(
    Directory dir, {
    required String name,
    required RemoteRepoSnapshot? remote,
    required bool isExplicitlyIgnored,
    required Map<String, String> canonicalSpotDefs,
  }) {
    final pubInfo = _scanLocalPubspec(dir);
    final workflows = _scanLocalWorkflows(dir);
    final hasRootLibOrBin =
        Directory(p.join(dir.path, 'lib')).existsSync() ||
        Directory(p.join(dir.path, 'bin')).existsSync();
    final hasSkillsMarkdown = _hasLocalSkillsMarkdown(dir);
    final kind = _determineKind(
      isExplicitlyIgnored: isExplicitlyIgnored,
      pub: pubInfo,
      workflows: workflows,
      hasRootLibOrBin: hasRootLibOrBin,
      hasSkillsMarkdown: hasSkillsMarkdown,
    );
    final analysis = _scanLocalAnalysisOptions(dir);
    final dependabot = _scanDependabotText(_readLocalDependabot(dir));
    final markdown = _scanLocalMarkdownConfig(dir);
    final spotDrift = scanRepoSpotDrift(
      dir,
      canonicalDefs: canonicalSpotDefs,
    ).map((i) => i.message).toList();
    final ghInfo = _gitHubInfoFromSnapshot(remote);

    return _assembleStatus(
      name: name,
      path: dir.path,
      kind: kind,
      pubInfo: pubInfo,
      analysis: analysis,
      workflows: workflows,
      dependabot: dependabot,
      markdown: markdown,
      spotDrift: spotDrift,
      ghInfo: ghInfo,
    );
  }

  RepoAlignmentStatus _buildStatusFromRemoteSnapshot(
    RemoteRepoSnapshot snap, {
    required bool isExplicitlyIgnored,
    required Map<String, String> canonicalSpotDefs,
  }) {
    final localDir = Directory(p.join(baseDirPath, snap.name));
    final pubInfo = _scanRemotePubspec(snap);
    final workflows = inspectWorkflowContents(snap.workflowFiles);
    final kind = _determineKind(
      isExplicitlyIgnored: isExplicitlyIgnored,
      pub: pubInfo,
      workflows: workflows,
      hasRootLibOrBin: snap.hasRootLibOrBin,
      hasSkillsMarkdown: snap.hasSkillsMarkdown,
    );
    final analysis = _scanRemoteAnalysisOptions(snap.analysisOptionsText);
    final dependabot = _scanDependabotText(snap.dependabotText);
    final markdown = (
      hasPrettierRc: snap.hasPrettierRc,
      hasMarkdownWorkflow:
          snap.workflowFiles.containsKey('markdown.yml') ||
          snap.workflowFiles.containsKey('markdown.yaml'),
      hasPrettierIgnore: snap.hasPrettierIgnore,
    );
    final spotDrift = _scanOriginHeadSpotDrift(
      localDir,
      canonicalDefs: canonicalSpotDefs,
    );
    final ghInfo = _gitHubInfoFromSnapshot(snap);

    return _assembleStatus(
      name: snap.name,
      path: localDir.path,
      kind: kind,
      pubInfo: pubInfo,
      analysis: analysis,
      workflows: workflows,
      dependabot: dependabot,
      markdown: markdown,
      spotDrift: spotDrift,
      ghInfo: ghInfo,
    );
  }

  RepoAlignmentStatus _assembleStatus({
    required String name,
    required String path,
    required RepoKind kind,
    required _PubspecInfo pubInfo,
    required _AnalysisInfo analysis,
    required WorkflowsScanInfo workflows,
    required ({bool hasDependabot, bool hasCanonicalDependabot}) dependabot,
    required _MarkdownInfo markdown,
    required List<String> spotDrift,
    required _GitHubInfo ghInfo,
  }) => RepoAlignmentStatus(
    name: name,
    path: path,
    kind: kind,
    isArchived: ghInfo.isArchived,
    isFork: ghInfo.isFork,
    isPrivate: ghInfo.isPrivate,
    defaultBranch: ghInfo.defaultBranch,
    hasPubspec: pubInfo.hasPubspec,
    sdkConstraint: pubInfo.sdkConstraint,
    packageNames: pubInfo.packageNames,
    hasPublishToNone: pubInfo.hasPublishToNone,
    hasApiSummaryDevDep: pubInfo.hasApiSummaryDevDep,
    hasApiTxt: pubInfo.hasApiTxt,
    hasApiTest: pubInfo.hasApiTest,
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
    spotDriftIssues: spotDrift,
    autoMergeAllowed: ghInfo.autoMergeAllowed,
    hasAutosubmitLabel: ghInfo.hasAutosubmitLabel,
    hasRulesetOrProtection: ghInfo.hasRulesetOrProtection,
    requiredChecks: ghInfo.requiredChecks,
    defaultBranchRulesetId: ghInfo.defaultBranchRulesetId,
    defaultBranchRequiredChecks: ghInfo.defaultBranchRequiredChecks,
  );

  RepoKind _determineKind({
    required bool isExplicitlyIgnored,
    required _PubspecInfo pub,
    required WorkflowsScanInfo workflows,
    required bool hasRootLibOrBin,
    required bool hasSkillsMarkdown,
  }) {
    if (isExplicitlyIgnored) return RepoKind.legacyOrIgnored;
    if (hasSkillsMarkdown &&
        !hasRootLibOrBin &&
        !workflows.hasPublish &&
        !pub.hasAnyApiTxt) {
      return RepoKind.agentSkills;
    }
    if (!pub.hasPubspec) return RepoKind.experimentalOrPrototype;
    if (!pub.hasPublishToNone) return RepoKind.publishedPackage;
    if (pub.isWorkspace) return RepoKind.monorepoWorkspace;
    return RepoKind.toolOrApp;
  }

  static bool _hasLocalSkillsMarkdown(Directory dir) {
    final skillsDir = Directory(p.join(dir.path, 'skills'));
    if (!skillsDir.existsSync()) return false;
    for (final entry in skillsDir.listSync().whereType<Directory>()) {
      if (File(p.join(entry.path, 'SKILL.md')).existsSync()) return true;
    }
    return false;
  }

  List<String> _scanOriginHeadSpotDrift(
    Directory localDir, {
    required Map<String, String> canonicalDefs,
  }) {
    if (!localDir.existsSync() || !_hasGitMetadata(localDir)) return const [];

    final grepRes = defaultGitCli.runSync(const [
      'grep',
      '-I',
      '-l',
      '-E',
      '(BEGIN|END) SPOT:',
      'origin/HEAD',
      '--',
      '*.md',
    ], workingDirectory: localDir.path);
    if (grepRes.exitCode != 0) return const [];

    final issues = <String>[];
    for (final rawLine in grepRes.stdout.toString().split('\n')) {
      final spec = rawLine.trim();
      if (!spec.startsWith('origin/HEAD:')) continue;
      final relPath = spec.substring('origin/HEAD:'.length);
      final text = defaultGitCli.stdoutOrNullSync([
        'show',
        spec,
      ], workingDirectory: localDir.path);
      if (text == null) continue;
      issues.addAll(
        checkSpotBlocksInLines(
          relPath,
          text.split('\n'),
          canonicalDefs: canonicalDefs,
        ).map((i) => i.message),
      );
    }
    return issues;
  }

  _PubspecInfo _scanLocalPubspec(Directory dir) {
    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return _emptyPubspecInfo();

    final acc = _PubspecScanAccumulator();
    final rootMeta = _parseRootPubspecText(
      pubspecFile.readAsStringSync(),
      acc,
      hasRootApiTxt: File(p.join(dir.path, 'api.txt')).existsSync(),
      hasRootApiTest: File(p.join(dir.path, 'test', 'api_test.dart'))
          .existsSync(),
      resolveMember: (member) => _readLocalSubPackage(dir, member),
    );

    if (!rootMeta.isWorkspace) {
      final pkgsDir = Directory(p.join(dir.path, 'packages'));
      if (pkgsDir.existsSync()) {
        for (final sub in pkgsDir.listSync().whereType<Directory>()) {
          acc.processPackageBlob(_readLocalDirectoryPackage(sub));
        }
      }
    }

    return acc.toInfo(
      sdkConstraint: rootMeta.sdkConstraint,
      isWorkspace: rootMeta.isWorkspace,
    );
  }

  _PubspecInfo _scanRemotePubspec(RemoteRepoSnapshot snap) {
    final rootText = snap.rootPubspecText;
    if (rootText == null) return _emptyPubspecInfo();

    final acc = _PubspecScanAccumulator();
    final rootMeta = _parseRootPubspecText(
      rootText,
      acc,
      hasRootApiTxt: snap.hasRootApiTxt,
      hasRootApiTest: snap.hasRootApiTest,
      resolveMember: (member) => snap.subPackages[member],
    );

    if (!rootMeta.isWorkspace) {
      for (final MapEntry(:key, :value) in snap.subPackages.entries) {
        if (key.startsWith('packages/')) {
          acc.processPackageBlob(value);
        }
      }
    }

    return acc.toInfo(
      sdkConstraint: rootMeta.sdkConstraint,
      isWorkspace: rootMeta.isWorkspace,
    );
  }

  RemotePackageBlobInfo? _readLocalSubPackage(Directory root, String member) =>
      _readLocalDirectoryPackage(Directory(p.join(root.path, member)));

  RemotePackageBlobInfo? _readLocalDirectoryPackage(Directory sub) {
    final pub = File(p.join(sub.path, 'pubspec.yaml'));
    if (!pub.existsSync()) return null;
    return (
      pubspecText: pub.readAsStringSync(),
      hasApiTxt: File(p.join(sub.path, 'api.txt')).existsSync(),
      hasApiTest: File(p.join(sub.path, 'test', 'api_test.dart')).existsSync(),
    );
  }

  ({String? sdkConstraint, bool isWorkspace}) _parseRootPubspecText(
    String rootText,
    _PubspecScanAccumulator acc, {
    required bool hasRootApiTxt,
    required bool hasRootApiTest,
    required RemotePackageBlobInfo? Function(String member) resolveMember,
  }) {
    try {
      final doc = loadYaml(rootText);
      if (doc is! YamlMap) return (sdkConstraint: null, isWorkspace: false);

      final env = doc['environment'];
      final sdkConstraint = (env is YamlMap && env['sdk'] != null)
          ? env['sdk'].toString()
          : null;
      final workspace = doc['workspace'];
      final isWorkspace = workspace != null;

      acc.processPackageBlob((
        pubspecText: rootText,
        hasApiTxt: hasRootApiTxt,
        hasApiTest: hasRootApiTest,
      ), isWorkspaceRoot: isWorkspace);

      if (workspace is YamlList) {
        for (final member in workspace) {
          final info = resolveMember(member.toString());
          if (info != null) acc.processPackageBlob(info);
        }
      }
      return (sdkConstraint: sdkConstraint, isWorkspace: isWorkspace);
    } catch (_) {
      return (sdkConstraint: null, isWorkspace: false);
    }
  }

  _PubspecInfo _emptyPubspecInfo() => (
    hasPubspec: false,
    sdkConstraint: null,
    isWorkspace: false,
    packageNames: const <String>[],
    hasPublishToNone: true,
    hasApiSummaryDevDep: false,
    hasApiTxt: false,
    hasAnyApiTxt: false,
    hasApiTest: false,
  );

  _AnalysisInfo _scanLocalAnalysisOptions(Directory dir) {
    final analysisFile = File(p.join(dir.path, 'analysis_options.yaml'));
    if (!analysisFile.existsSync()) return _emptyAnalysisInfo;

    final content = analysisFile.readAsStringSync();
    final resolver = AnalysisOptionsResolver.createSync(
      packageDirectory: dir,
      fallbackDirectory: Directory(baseDirPath),
    );
    return _buildAnalysisInfo(
      content,
      resolver.resolveFromFile(analysisFile.path),
    );
  }

  _AnalysisInfo _scanRemoteAnalysisOptions(String? content) {
    if (content == null) return _emptyAnalysisInfo;
    final resolved = AnalysisOptionsResolver().resolveFromContent(content);
    return _buildAnalysisInfo(content, resolved);
  }

  _AnalysisInfo _buildAnalysisInfo(
    String rawContent,
    ResolvedAnalysisOptions resolved,
  ) {
    String? analysisInclude;
    try {
      final doc = loadYaml(rawContent);
      if (doc is YamlMap && doc['include'] != null) {
        analysisInclude = doc['include'].toString();
      }
    } catch (_) {}

    final allLang = resolved.allLanguage;
    return (
      hasAnalysisOptions: true,
      analysisInclude: analysisInclude,
      strictCasts: allLang['strict-casts'] == true,
      strictInference: allLang['strict-inference'] == true,
      strictRawTypes: allLang['strict-raw-types'] == true,
      customLints: resolved.explicitLints.toList()..sort(),
    );
  }

  static const _emptyAnalysisInfo = (
    hasAnalysisOptions: false,
    analysisInclude: null,
    strictCasts: false,
    strictInference: false,
    strictRawTypes: false,
    customLints: <String>[],
  );

  _MarkdownInfo _scanLocalMarkdownConfig(Directory dir) {
    final workflows = p.join(dir.path, '.github', 'workflows');
    final hasMarkdownWorkflow =
        File(p.join(workflows, 'markdown.yml')).existsSync() ||
        File(p.join(workflows, 'markdown.yaml')).existsSync();
    return (
      hasPrettierRc: File(p.join(dir.path, '.prettierrc.json')).existsSync(),
      hasMarkdownWorkflow: hasMarkdownWorkflow,
      hasPrettierIgnore: File(p.join(dir.path, '.prettierignore')).existsSync(),
    );
  }

  WorkflowsScanInfo _scanLocalWorkflows(Directory dir) {
    final workflowsDir = Directory(p.join(dir.path, '.github', 'workflows'));
    if (!workflowsDir.existsSync()) return emptyWorkflowsScanInfo;

    final files = <String, String>{};
    for (final wf in workflowsDir.listSync().whereType<File>()) {
      final name = p.basename(wf.path);
      if (name.endsWith('.yml') || name.endsWith('.yaml')) {
        files[name] = wf.readAsStringSync();
      }
    }
    return inspectWorkflowContents(files);
  }

  String? _readLocalDependabot(Directory dir) {
    final d1 = File(p.join(dir.path, '.github', 'dependabot.yml'));
    if (d1.existsSync()) return d1.readAsStringSync();
    final d2 = File(p.join(dir.path, '.github', 'dependabot.yaml'));
    if (d2.existsSync()) return d2.readAsStringSync();
    return null;
  }

  ({bool hasDependabot, bool hasCanonicalDependabot}) _scanDependabotText(
    String? content,
  ) {
    if (content == null) {
      return (hasDependabot: false, hasCanonicalDependabot: false);
    }
    final hasCanonical =
        content.contains('github-actions') &&
        content.contains('groups:') &&
        content.contains('autosubmit');
    return (hasDependabot: true, hasCanonicalDependabot: hasCanonical);
  }

  _GitHubInfo _gitHubInfoFromSnapshot(RemoteRepoSnapshot? snap) {
    if (snap == null) {
      return (
        isArchived: false,
        isFork: false,
        isPrivate: false,
        defaultBranch: 'main',
        autoMergeAllowed: false,
        hasAutosubmitLabel: true,
        hasRulesetOrProtection: false,
        requiredChecks: const <String>[],
        defaultBranchRulesetId: null,
        defaultBranchRequiredChecks: const <String>[],
      );
    }
    return (
      isArchived: snap.isArchived,
      isFork: snap.isFork,
      isPrivate: snap.isPrivate,
      defaultBranch: snap.defaultBranch,
      autoMergeAllowed: snap.autoMergeAllowed,
      hasAutosubmitLabel: snap.hasAutosubmitLabel,
      hasRulesetOrProtection: snap.hasRulesetOrProtection,
      requiredChecks: snap.requiredChecks,
      defaultBranchRulesetId: snap.defaultBranchRulesetId,
      defaultBranchRequiredChecks: snap.defaultBranchRequiredChecks,
    );
  }
}

typedef _PubspecInfo = ({
  bool hasPubspec,
  String? sdkConstraint,
  bool isWorkspace,
  List<String> packageNames,
  bool hasPublishToNone,
  bool hasApiSummaryDevDep,
  bool hasApiTxt,
  bool hasAnyApiTxt,
  bool hasApiTest,
});

typedef _AnalysisInfo = ({
  bool hasAnalysisOptions,
  String? analysisInclude,
  bool strictCasts,
  bool strictInference,
  bool strictRawTypes,
  List<String> customLints,
});

typedef _MarkdownInfo = ({
  bool hasPrettierRc,
  bool hasMarkdownWorkflow,
  bool hasPrettierIgnore,
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

class _PubspecScanAccumulator {
  final packageNames = <String>[];
  int publishedCount = 0;
  int apiTxtCount = 0;
  int anyApiTxtCount = 0;
  int apiTestCount = 0;
  int apiSummaryDevDepCount = 0;

  void processPackageBlob(
    RemotePackageBlobInfo? pkg, {
    bool isWorkspaceRoot = false,
  }) {
    final text = pkg?.pubspecText;
    if (pkg == null || text == null) return;
    if (pkg.hasApiTxt) anyApiTxtCount++;
    try {
      final doc = loadYaml(text);
      if (doc is! YamlMap) return;
      _recordPackageName(doc);
      if (isWorkspaceRoot) return;
      _recordPublishedPackage(pkg, doc);
    } catch (_) {}
  }

  void _recordPackageName(YamlMap doc) {
    final name = doc['name']?.toString();
    if (name != null && !packageNames.contains(name)) {
      packageNames.add(name);
    }
  }

  void _recordPublishedPackage(RemotePackageBlobInfo pkg, YamlMap doc) {
    if (doc['publish_to']?.toString() == 'none' || doc['version'] == null) {
      return;
    }
    publishedCount++;
    if (pkg.hasApiTxt) apiTxtCount++;
    if (pkg.hasApiTest) apiTestCount++;
    final devDeps = doc['dev_dependencies'];
    if (devDeps is YamlMap && devDeps.containsKey('api_summary')) {
      apiSummaryDevDepCount++;
    }
  }

  _PubspecInfo toInfo({
    required String? sdkConstraint,
    required bool isWorkspace,
  }) => (
    hasPubspec: true,
    sdkConstraint: sdkConstraint,
    isWorkspace: isWorkspace,
    packageNames: packageNames,
    hasPublishToNone: publishedCount == 0,
    hasApiSummaryDevDep:
        publishedCount > 0 && apiSummaryDevDepCount == publishedCount,
    hasApiTxt: publishedCount > 0 && apiTxtCount == publishedCount,
    hasAnyApiTxt: anyApiTxtCount > 0,
    hasApiTest: publishedCount > 0 && apiTestCount == publishedCount,
  );
}
