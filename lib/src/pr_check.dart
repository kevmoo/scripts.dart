import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/args.dart';
import 'package:cli_util/cli_util.dart';
import 'package:firehose/firehose.dart' as firehose;
import 'package:io/ansi.dart' as ansi;
import 'package:io/io.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'process_utils.dart';
import 'shared/gh_args.dart';
import 'testable_print.dart';

part 'pr_check_agent_docs.dart';

/// Pinned `package:cognitive_complexity` version used for `dart run` checks.
const cognitiveComplexityPinnedVersion = '2.0.1';

/// Package specification passed to `dart run` for cognitive complexity checks.
const cognitiveComplexityPackageSpec =
    'cognitive_complexity@^$cognitiveComplexityPinnedVersion';

/// A single local CI parity violation detected before opening/updating a PR.
final class PrCheckViolation {
  final String check;
  final String message;
  final String remediation;

  const new({
    required this.check,
    required this.message,
    required this.remediation,
  });
}

/// A single pre-PR check that was skipped, along with the reason.
final class PrCheckSkip {
  final String check;
  final String reason;

  const new({required this.check, required this.reason});

  @override
  String toString() => '$check ($reason)';
}

/// Summary of a `pr-check` run against a repository worktree.
final class PrCheckReport {
  final String baseRef;
  final List<String> changedFiles;
  final List<PrCheckViolation> violations;
  final List<String> passedChecks;
  final List<PrCheckSkip> skippedChecks;
  final List<String> warnings;

  const new({
    required this.baseRef,
    required this.changedFiles,
    required this.violations,
    this.passedChecks = const [],
    this.skippedChecks = const [],
    this.warnings = const [],
  });

  bool get passed => violations.isEmpty;
}

ArgParser _buildPrCheckArgParser() => ArgParser()
  ..addOption(
    'dir',
    abbr: 'd',
    help: 'Repository or worktree directory to validate.',
    defaultsTo: '.',
  )
  ..addOption(
    'base',
    abbr: 'b',
    help: 'Base git ref to diff against (defaults to origin/HEAD or main).',
  )
  ..addFlag(
    'require-wip',
    help:
        'Require touched publishable packages at a released version to bump '
        'to a -wip version.',
    defaultsTo: true,
  )
  ..addFlag(
    'test',
    abbr: 't',
    negatable: false,
    help: 'Run "dart test" in touched packages that have a test/ directory.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this usage information.',
  );

/// Entrypoint for `pr-check` and `kscripts pr-check`.
Future<void> runPrCheckCli(
  List<String> args, {
  SyncProcessRunner processRunner = defaultSyncProcessRunner,
  Future<String?> Function()? fetchLatestCognitiveComplexityVersion,
}) async {
  final parser = _buildPrCheckArgParser();
  final results = parseCliArgs(
    parser,
    args,
    commandName: 'pr-check',
    description: 'Validate local CI parity before running gh pr create.',
  );
  if (results == null) return;

  final targetDir = Directory(
    p.normalize(p.absolute(results['dir'] as String)),
  );
  if (!targetDir.existsSync()) {
    setError(
      message: 'Directory does not exist: ${targetDir.path}',
      exitCode: ExitCode.noInput.code,
    );
    return;
  }

  final versionFuture = _fetchLatestCognitiveComplexityVersion(
    processRunner: processRunner,
    customFetcher: fetchLatestCognitiveComplexityVersion,
  );

  final report = runPrCheck(
    directory: targetDir,
    baseRefOverride: results['base'] as String?,
    requireWip: results['require-wip'] as bool,
    runTests: results['test'] as bool,
    processRunner: processRunner,
  );

  final latestVersion = await versionFuture.timeout(
    const Duration(milliseconds: 500),
    onTimeout: () => null,
  );
  final versionNote = checkCognitiveComplexityVersionNote(latestVersion);
  for (final warning in [...report.warnings, ?versionNote]) {
    print(ansi.yellow.wrap('💡 [pr-check] $warning'));
  }

  if (!report.passed) {
    setError(
      message: _formatViolations(report),
      exitCode: ExitCode.software.code,
    );
    return;
  }

  print(
    ansi.green.wrap(
      '✅ [pr-check] All local CI parity checks passed '
      '(${report.changedFiles.length} touched file(s) vs ${report.baseRef}).',
    ),
  );
  if (report.passedChecks.isNotEmpty) {
    print('  Ran: ${report.passedChecks.join(', ')}');
  }
  if (report.skippedChecks.isNotEmpty) {
    print('  Skipped: ${report.skippedChecks.join(', ')}');
  }
}

Future<String?> _fetchLatestCognitiveComplexityVersion({
  required SyncProcessRunner processRunner,
  required Future<String?> Function()? customFetcher,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (customFetcher != null) return customFetcher();
  if (processRunner != defaultSyncProcessRunner) return null;
  try {
    return await Isolate.run(
      () => _queryPubDevLatestVersion('cognitive_complexity', timeout),
    ).timeout(timeout, onTimeout: () => null);
  } catch (_) {
    return null;
  }
}

Future<String?> _queryPubDevLatestVersion(
  String packageName,
  Duration timeout,
) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final uri = Uri.https('pub.dev', '/api/packages/$packageName');
    final request = await client.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) return null;
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) return null;
    final latest = decoded['latest'];
    return latest is Map<String, Object?> && latest['version'] is String
        ? latest['version'] as String
        : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Returns an FYI note if [latestVersionStr] is a newer stable release than
/// [cognitiveComplexityPinnedVersion], or `null` otherwise.
String? checkCognitiveComplexityVersionNote(String? latestVersionStr) {
  if (latestVersionStr == null || latestVersionStr.isEmpty) return null;
  try {
    final latest = Version.parse(latestVersionStr);
    final pinned = Version.parse(cognitiveComplexityPinnedVersion);
    if (!latest.isPreRelease && latest > pinned) {
      return 'FYI: package:cognitive_complexity $latest is available on '
          'pub.dev (pr-check pins ^$cognitiveComplexityPinnedVersion; '
          'revisit cognitiveComplexityPinnedVersion in pr_check.dart).';
    }
  } catch (_) {
    // Ignore malformed version strings.
  }
  return null;
}

String _formatViolations(PrCheckReport report) {
  final buf = StringBuffer()
    ..writeln(
      ansi.red.wrap(
        '❌ [pr-check] ${report.violations.length} local CI validation '
        'check(s) failed (diff vs ${report.baseRef}):',
      ),
    );
  for (final v in report.violations) {
    buf
      ..writeln()
      ..writeln(ansi.styleBold.wrap('  • [${v.check}] ${v.message}'))
      ..writeln('    💡 Fix: ${v.remediation}');
  }
  if (report.passedChecks.isNotEmpty || report.skippedChecks.isNotEmpty) {
    buf.writeln();
    if (report.passedChecks.isNotEmpty) {
      buf.writeln('  Ran (passed): ${report.passedChecks.join(', ')}');
    }
    if (report.skippedChecks.isNotEmpty) {
      buf.writeln('  Skipped: ${report.skippedChecks.join(', ')}');
    }
  }
  return buf.toString().trimRight();
}

/// Runs all deterministic pre-PR checks on [directory].
PrCheckReport runPrCheck({
  required Directory directory,
  String? baseRefOverride,
  bool requireWip = true,
  bool runTests = false,
  String? latestCognitiveComplexityVersion,
  SyncProcessRunner processRunner = defaultSyncProcessRunner,
}) {
  final repoRoot = _resolveGitTopLevel(directory, processRunner) ?? directory;
  final baseRef = _resolveBaseRef(repoRoot, baseRefOverride, processRunner);
  final changedFiles = _collectChangedFiles(repoRoot, baseRef, processRunner);
  final runner = _PrCheckRunner(
    repoRoot: repoRoot,
    baseRef: baseRef,
    changedFiles: changedFiles,
    workflowsText: changedFiles.isEmpty ? '' : _readWorkflowsContent(repoRoot),
    dartBin: _resolveDartBinary(),
    isDartSdk: File(p.join(repoRoot.path, 'tools', 'VERSION')).existsSync(),
    runSync: processRunner,
  );
  return runner.run(
    requireWip: requireWip,
    runTests: runTests,
    latestCognitiveComplexityVersion: latestCognitiveComplexityVersion,
  );
}

final class _PrCheckRunner {
  final Directory repoRoot;
  final String baseRef;
  final List<String> changedFiles;
  final String workflowsText;
  final String dartBin;
  final bool isDartSdk;
  final SyncProcessRunner runSync;

  final violations = <PrCheckViolation>[];
  final passedChecks = <String>[];
  final skippedChecks = <PrCheckSkip>[];
  final warnings = <String>[];

  new({
    required this.repoRoot,
    required this.baseRef,
    required this.changedFiles,
    required this.workflowsText,
    required this.dartBin,
    required this.isDartSdk,
    required this.runSync,
  });

  PrCheckReport run({
    required bool requireWip,
    required bool runTests,
    required String? latestCognitiveComplexityVersion,
  }) {
    final versionNote = checkCognitiveComplexityVersionNote(
      latestCognitiveComplexityVersion,
    );
    if (versionNote != null) warnings.add(versionNote);

    _recordSingle('git-status', _checkCleanWorkingTree(repoRoot, runSync));
    if (changedFiles.isEmpty) {
      _skip('diff-checks', 'no changed files vs $baseRef');
      return _toReport();
    }

    _runFirehoseChecks(requireWip: requireWip);
    _runDartFileChecks(changedFiles.where((f) => f.endsWith('.dart')).toList());
    _runMarkdownChecks(changedFiles.where((f) => f.endsWith('.md')).toList());
    _runPackageTestChecks(runTests: runTests);
    return _toReport();
  }

  PrCheckReport _toReport() => PrCheckReport(
    baseRef: baseRef,
    changedFiles: changedFiles,
    violations: violations,
    passedChecks: passedChecks,
    skippedChecks: skippedChecks,
    warnings: warnings,
  );

  void _recordSingle(String checkName, PrCheckViolation? violation) {
    if (violation != null) {
      violations.add(violation);
    } else {
      passedChecks.add(checkName);
    }
  }

  void _recordMulti(String checkName, List<PrCheckViolation> found) {
    if (found.isNotEmpty) {
      violations.addAll(found);
    } else {
      passedChecks.add(checkName);
    }
  }

  void _skip(String checkName, String reason) {
    skippedChecks.add(PrCheckSkip(check: checkName, reason: reason));
  }

  void _runFirehoseChecks({required bool requireWip}) {
    final packages = runZoned(
      () => firehose.Repository(repoRoot).locatePackages(),
      zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
    );
    final changedSet = changedFiles.toSet();
    var checkedAny = false;
    for (final pkg in packages) {
      if (_validateFirehosePackage(pkg, changedSet, requireWip: requireWip)) {
        checkedAny = true;
      }
    }
    if (!checkedAny) {
      _skip('firehose', 'no touched publishable packages');
    }
  }

  bool _validateFirehosePackage(
    firehose.Package pkg,
    Set<String> changedSet, {
    required bool requireWip,
  }) {
    final relDir = p.relative(pkg.directory.path, from: repoRoot.path);
    final prefix = relDir == '.' ? '' : '$relDir/';
    final pkgChanged = _packageRelativeChanges(prefix, changedSet);
    final ver = pkg.version;
    if (pkgChanged.isEmpty || ver == null) return false;

    final pkgViolations = <PrCheckViolation>[];
    final verStr = ver.toString();
    final changelogPath = '${prefix}CHANGELOG.md';
    final changelogVer = pkg.changelog.latestVersion;
    if (pkg.changelog.exists && changelogVer != verStr) {
      pkgViolations.add(
        PrCheckViolation(
          check: 'firehose-changelog',
          message:
              'package:${pkg.name} pubspec.yaml version ($verStr) does not '
              'match CHANGELOG.md top entry ($changelogVer).',
          remediation:
              'Prepend "## $verStr" to $changelogPath or align pubspec.yaml.',
        ),
      );
    }

    final versionDart = File(
      p.join(pkg.directory.path, 'lib', 'src', 'version.dart'),
    );
    if (versionDart.existsSync() &&
        !versionDart.readAsStringSync().contains(verStr)) {
      final relVerPath = '${prefix}lib/src/version.dart';
      pkgViolations.add(
        PrCheckViolation(
          check: 'version-dart-sync',
          message:
              'package:${pkg.name} is at $verStr, but '
              '$relVerPath does not contain $verStr.',
          remediation: 'Regenerate or update $relVerPath to match $verStr.',
        ),
      );
    }

    final pubspecRel = '${prefix}pubspec.yaml';
    final baseVer = _readBasePubspecVersion(
      repoRoot,
      baseRef,
      pubspecRel,
      runSync,
    );
    if (requireWip &&
        pkgChanged.any(_isCodeOrPackageFile) &&
        !ver.isPreRelease &&
        (baseVer == null || baseVer == verStr)) {
      final nextWip = '${ver.major}.${ver.minor}.${ver.patch + 1}-wip';
      pkgViolations.add(
        PrCheckViolation(
          check: 'pubspec-wip-bump',
          message:
              'package:${pkg.name} is at released version $verStr without a '
              '-wip bump in $pubspecRel.',
          remediation:
              'Bump $pubspecRel to "version: $nextWip" and add "## $nextWip" '
              'to $changelogPath.',
        ),
      );
    }

    if (ver.isPreRelease &&
        !pkgChanged.contains('CHANGELOG.md') &&
        pkgChanged.any(_isFirehoseChangelogWatchedFile)) {
      warnings.add(
        'TIP: package:${pkg.name} ($verStr) modified lib/bin/pubspec without '
        'updating $changelogPath. Add a changelog entry or apply the '
        '"skip-changelog-check" PR label.',
      );
    }

    _recordMulti('firehose:${pkg.name}', pkgViolations);
    return true;
  }

  void _runDartFileChecks(List<String> dartFiles) {
    if (dartFiles.isEmpty || isDartSdk) {
      final reason = isDartSdk ? 'Dart SDK repo' : 'no touched .dart files';
      _skip('dart-format', reason);
      _skip('dart-analyze-fatal-infos', reason);
      _skip('cognitive-complexity', reason);
      _skip('browser-test-on-vm', reason);
      return;
    }

    _recordSingle(
      'dart-format',
      _checkDartFormat(repoRoot, dartFiles, dartBin, runSync),
    );
    _recordSingle(
      'dart-analyze-fatal-infos',
      _checkDartAnalyzeFatalInfos(repoRoot, dartFiles, dartBin, runSync),
    );

    if (!workflowsText.contains('cognitive_complexity')) {
      _skip('cognitive-complexity', 'not in workflows');
    } else {
      final libBinFiles = dartFiles.where(_isLibOrBinDartFile).toList();
      if (libBinFiles.isEmpty) {
        _skip('cognitive-complexity', 'no touched lib/ or bin/ .dart files');
      } else {
        _recordSingle(
          'cognitive-complexity',
          _checkCognitiveComplexity(repoRoot, libBinFiles, dartBin, runSync),
        );
      }
    }

    if (!RegExp(r'\b(chrome|wasm|firefox)\b').hasMatch(workflowsText)) {
      _skip('browser-test-on-vm', 'no browser/wasm in workflows');
    } else {
      final testFiles = dartFiles
          .where((f) => f.endsWith('_test.dart'))
          .toList();
      if (testFiles.isEmpty) {
        _skip('browser-test-on-vm', 'no touched *_test.dart files');
      } else {
        _recordMulti(
          'browser-test-on-vm',
          _checkBrowserTestOnVm(repoRoot, testFiles),
        );
      }
    }
  }

  void _runMarkdownChecks(List<String> mdFiles) {
    if (mdFiles.isEmpty) {
      _skip('gfm-markdown', 'no touched .md files');
      _skip('agent-docs', 'no touched .md files');
      _skip('prettier-markdown', 'no touched .md files');
      return;
    }

    _recordMulti(
      'gfm-markdown',
      _checkGitHubMarkdownConventions(repoRoot, mdFiles),
    );

    final agentDocFiles = mdFiles.where(_isAgentDocPath).toList();
    if (agentDocFiles.isEmpty) {
      _skip(
        'agent-docs',
        'no touched SKILL.md, AGENTS.md, or references/ files',
      );
    } else {
      _recordMulti('agent-docs', checkAgentDocFiles(repoRoot, agentDocFiles));
    }

    final hasPrettier =
        workflowsText.toLowerCase().contains('prettier') ||
        File(p.join(repoRoot.path, '.prettierrc.json')).existsSync();
    if (!hasPrettier) {
      _skip('prettier-markdown', 'no .prettierrc.json or workflow');
    } else {
      _recordSingle(
        'prettier-markdown',
        _checkPrettierMarkdown(repoRoot, mdFiles, runSync),
      );
    }
  }

  void _runPackageTestChecks({required bool runTests}) {
    if (!runTests) {
      _skip('dart-test', 'pass --test to run');
      return;
    }
    if (isDartSdk) {
      _skip('dart-test', 'Dart SDK repo');
      return;
    }
    final testPkgDirs = _findTouchedTestablePackageDirs(repoRoot, changedFiles);
    if (testPkgDirs.isEmpty) {
      _skip('dart-test', 'no touched packages with test/');
      return;
    }
    for (final pkgRelDir in testPkgDirs) {
      final label = pkgRelDir == '.' ? 'dart-test' : 'dart-test:$pkgRelDir';
      final workDir = pkgRelDir == '.'
          ? repoRoot.path
          : p.join(repoRoot.path, pkgRelDir);
      final res = runSync(dartBin, ['test'], workingDirectory: workDir);
      if (res.exitCode == 0) {
        passedChecks.add(label);
      } else {
        final out = '${res.stdout}\n${res.stderr}'.trim();
        final fixCmd = pkgRelDir == '.'
            ? 'dart test'
            : '(cd $pkgRelDir && dart test)';
        violations.add(
          PrCheckViolation(
            check: 'dart-test',
            message: 'dart test failed in $pkgRelDir:\n$out',
            remediation: 'Run "$fixCmd" and fix failing tests.',
          ),
        );
      }
    }
  }
}

List<String> _findTouchedTestablePackageDirs(
  Directory repoRoot,
  List<String> changedFiles,
) {
  final dirs = <String>{};
  for (final relPath in changedFiles) {
    if (relPath.startsWith('.github/')) continue;
    final owningPkg = _findOwningPackageRelDir(repoRoot, relPath);
    if (owningPkg == null) continue;
    if (Directory(p.join(repoRoot.path, owningPkg, 'test')).existsSync()) {
      dirs.add(owningPkg);
    }
  }
  return dirs.toList()..sort();
}

String? _findOwningPackageRelDir(Directory repoRoot, String relFilePath) {
  var dir = p.dirname(relFilePath);
  while (true) {
    if (File(p.join(repoRoot.path, dir, 'pubspec.yaml')).existsSync()) {
      return dir;
    }
    if (dir == '.' || dir.isEmpty) return null;
    dir = p.dirname(dir);
  }
}

Directory? _resolveGitTopLevel(Directory dir, SyncProcessRunner runSync) {
  final res = runSync('git', [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: dir.path);
  if (res.exitCode != 0) return null;
  final out = (res.stdout as String).trim();
  return out.isEmpty ? null : Directory(out);
}

PrCheckViolation? _checkCleanWorkingTree(
  Directory repoRoot,
  SyncProcessRunner runSync,
) {
  final res = runSync('git', [
    'status',
    '--porcelain',
  ], workingDirectory: repoRoot.path);
  if (res.exitCode != 0) return null;
  final dirty = (res.stdout as String).trim();
  if (dirty.isEmpty) return null;
  return PrCheckViolation(
    check: 'git-status',
    message: 'Uncommitted or untracked files in working tree:\n$dirty',
    remediation:
        'Stage, commit (or gitignore), and push all changes before '
        'PR creation.',
  );
}

String _resolveBaseRef(
  Directory repoRoot,
  String? override,
  SyncProcessRunner runSync,
) {
  final candidates = <String>[
    if (override != null && override.isNotEmpty) ...[
      override,
      if (!override.startsWith('origin/')) 'origin/$override',
    ],
    'origin/HEAD',
    'origin/main',
    'origin/master',
    'HEAD~1',
  ];
  for (final ref in candidates) {
    final res = runSync('git', [
      'rev-parse',
      '--verify',
      ref,
    ], workingDirectory: repoRoot.path);
    if (res.exitCode == 0) return ref;
  }
  return 'HEAD';
}

List<String> _collectChangedFiles(
  Directory repoRoot,
  String baseRef,
  SyncProcessRunner runSync,
) {
  final res = runSync('git', [
    'diff',
    '--name-only',
    '--diff-filter=ACMR',
    '$baseRef...HEAD',
  ], workingDirectory: repoRoot.path);
  if (res.exitCode != 0) return const [];
  return (res.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && File(p.join(repoRoot.path, s)).existsSync())
      .toList();
}

String _readWorkflowsContent(Directory repoRoot) {
  final wfDir = Directory(p.join(repoRoot.path, '.github', 'workflows'));
  if (!wfDir.existsSync()) return '';
  final buf = StringBuffer();
  for (final file in wfDir.listSync().whereType<File>()) {
    if (file.path.endsWith('.yml') || file.path.endsWith('.yaml')) {
      buf.writeln(file.readAsStringSync());
    }
  }
  return buf.toString();
}

String _resolveDartBinary() {
  final home = Platform.environment['HOME'];
  if (home != null) {
    final flutterDart = File(p.join(home, 'github', 'flutter', 'bin', 'dart'));
    if (flutterDart.existsSync()) return flutterDart.path;
  }
  return dartExecutable ?? 'dart';
}

List<String> _packageRelativeChanges(String prefix, Set<String> changedFiles) {
  final result = <String>[];
  for (final f in changedFiles) {
    if (prefix.isEmpty) {
      if (!f.startsWith('.github/')) result.add(f);
    } else if (f.startsWith(prefix)) {
      result.add(f.substring(prefix.length));
    }
  }
  return result;
}

bool _isCodeOrPackageFile(String relToPkg) =>
    relToPkg == 'pubspec.yaml' ||
    relToPkg.startsWith('lib/') ||
    relToPkg.startsWith('bin/') ||
    relToPkg.startsWith('test/') ||
    relToPkg.startsWith('tool/') ||
    relToPkg.startsWith('hook/') ||
    relToPkg.startsWith('web/');

bool _isFirehoseChangelogWatchedFile(String relToPkg) =>
    relToPkg == 'pubspec.yaml' ||
    relToPkg.startsWith('lib/') ||
    relToPkg.startsWith('bin/');

String? _readBasePubspecVersion(
  Directory repoRoot,
  String baseRef,
  String pubspecRel,
  SyncProcessRunner runSync,
) {
  final res = runSync('git', [
    'show',
    '$baseRef:$pubspecRel',
  ], workingDirectory: repoRoot.path);
  if (res.exitCode != 0) return null;
  final out = res.stdout as String;
  if (out.isEmpty) return null;
  return RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(out)?.group(1);
}

PrCheckViolation? _checkDartFormat(
  Directory repoRoot,
  List<String> dartFiles,
  String dartBin,
  SyncProcessRunner runSync,
) {
  final res = runSync(dartBin, [
    'format',
    '--output=none',
    '--set-exit-if-changed',
    ...dartFiles,
  ], workingDirectory: repoRoot.path);
  if (res.exitCode == 0) return null;
  return PrCheckViolation(
    check: 'dart-format',
    message:
        'Unformatted Dart file(s) detected:\n'
        '${(res.stdout as String).trim()}',
    remediation: 'dart format ${dartFiles.join(' ')}',
  );
}

PrCheckViolation? _checkDartAnalyzeFatalInfos(
  Directory repoRoot,
  List<String> dartFiles,
  String dartBin,
  SyncProcessRunner runSync,
) {
  final res = runSync(dartBin, [
    'analyze',
    '--fatal-infos',
    ...dartFiles,
  ], workingDirectory: repoRoot.path);
  if (res.exitCode == 0) return null;
  final out = '${res.stdout}\n${res.stderr}'.trim();
  return PrCheckViolation(
    check: 'dart-analyze-fatal-infos',
    message:
        'dart analyze --fatal-infos failed (bare `dart analyze` ignores '
        'info-level lints that fail CI):\n$out',
    remediation:
        'Run "dart pub get" (if uninitialized) and fix the analyzer '
        'diagnostics above (e.g. dart fix --apply).',
  );
}

PrCheckViolation? _checkCognitiveComplexity(
  Directory repoRoot,
  List<String> libBinFiles,
  String dartBin,
  SyncProcessRunner runSync,
) {
  final res = runSync(dartBin, [
    'run',
    cognitiveComplexityPackageSpec,
    '--fail-threshold',
    '15',
    ...libBinFiles,
  ], workingDirectory: repoRoot.path);
  if (res.exitCode == 0) return null;
  final out = '${res.stdout}\n${res.stderr}'.trim();
  return PrCheckViolation(
    check: 'cognitive-complexity',
    message:
        'Repository CI enforces cognitive_complexity <= 15, which failed:\n'
        '$out',
    remediation:
        'Decompose functions exceeding threshold 15 in '
        '${libBinFiles.join(', ')}.',
  );
}

bool _isLibOrBinDartFile(String path) =>
    path.startsWith('lib/') ||
    path.contains('/lib/') ||
    path.startsWith('bin/') ||
    path.contains('/bin/');

List<PrCheckViolation> _checkBrowserTestOnVm(
  Directory repoRoot,
  List<String> testFiles,
) {
  final violations = <PrCheckViolation>[];
  final ioImportRegex = RegExp(r'''import\s+['"]dart:(io|ffi)['"]''');
  final testOnVmRegex = RegExp(r'''@TestOn\(\s*['"]vm['"]\s*\)''');

  for (final relPath in testFiles) {
    final content = File(p.join(repoRoot.path, relPath)).readAsStringSync();
    if (ioImportRegex.hasMatch(content) && !testOnVmRegex.hasMatch(content)) {
      violations.add(
        PrCheckViolation(
          check: 'browser-test-on-vm',
          message:
              '$relPath imports dart:io or dart:ffi without @TestOn(\'vm\'), '
              'but CI workflow runs browser/wasm tests.',
          remediation:
              'Add "@TestOn(\'vm\')\\nlibrary;" at the top of $relPath.',
        ),
      );
    }
  }
  return violations;
}

PrCheckViolation? _checkPrettierMarkdown(
  Directory repoRoot,
  List<String> mdFiles,
  SyncProcessRunner runSync,
) {
  final res = runSync('npx', [
    '--yes',
    'prettier@3.9.6',
    '--check',
    ...mdFiles,
  ], workingDirectory: repoRoot.path);
  if (res.exitCode == 0) return null;
  return PrCheckViolation(
    check: 'prettier-markdown',
    message:
        'Markdown file(s) failed Prettier formatting check: '
        '${mdFiles.join(', ')}',
    remediation: 'npx --yes prettier@3.9.6 --write ${mdFiles.join(' ')}',
  );
}

final _gfmAlertNestedRegex = RegExp(
  r'^\s*>\s*>+\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]',
);
final _gfmAlertInlineRegex = RegExp(
  r'^\s*>\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s+\S',
);
final _gfmAlertHeaderRegex = RegExp(
  r'^\s*>\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$',
);
final _gfmAlertBodyLineRegex = RegExp(r'^\s*>\s*\S');
final _google3DirectiveRegex = RegExp(r'<!--\s*mdformat\b|^\s*\[TOC\]\s*$');

List<PrCheckViolation> _checkGitHubMarkdownConventions(
  Directory repoRoot,
  List<String> mdFiles,
) {
  final violations = <PrCheckViolation>[];
  for (final relPath in mdFiles) {
    final file = File(p.join(repoRoot.path, relPath));
    if (!file.existsSync()) continue;
    violations.addAll(
      checkGitHubMarkdownLines(relPath, file.readAsLinesSync()),
    );
  }
  return violations;
}

/// Validates that [lines] from [relPath] follow GitHub Flavored Markdown
/// conventions (Prettier-safe GFM alerts with an empty `>` separator line, no
/// Google3-only `<!-- mdformat ... -->` or `[TOC]` directives, and no Unicode
/// em/en-dashes inside executable code blocks or inline CLI flags).
List<PrCheckViolation> checkGitHubMarkdownLines(
  String relPath,
  List<String> lines,
) {
  final violations = <PrCheckViolation>[];
  _FenceState? activeFence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final nextFence = _updateFenceState(activeFence, line);
    if (activeFence != null || nextFence != null) {
      final fenceViolation = _checkFencedMarkdownLine(
        relPath,
        i + 1,
        line,
        activeFence,
        nextFence,
      );
      if (fenceViolation != null) violations.add(fenceViolation);
      activeFence = nextFence;
      continue;
    }
    final nextLine = i + 1 < lines.length ? lines[i + 1] : null;
    final bodyLine = i + 2 < lines.length ? lines[i + 2] : null;
    final violation = _checkSingleMarkdownLine(
      relPath,
      i + 1,
      line,
      nextLine,
      bodyLine,
    );
    if (violation != null) violations.add(violation);
  }
  return violations;
}

PrCheckViolation? _checkSingleMarkdownLine(
  String relPath,
  int lineNumber,
  String line,
  String? nextLine,
  String? bodyLine,
) {
  if (_gfmAlertNestedRegex.hasMatch(line)) {
    return PrCheckViolation(
      check: 'gfm-alert-format',
      message:
          '$relPath:$lineNumber nests a GitHub Alert inside a blockquote '
          '(> > [!TYPE]), which GitHub renders as a plain blockquote.',
      remediation: 'Move `> [!TYPE]` to a top-level blockquote (`> [!TYPE]`).',
    );
  }
  if (_gfmAlertInlineRegex.hasMatch(line)) {
    return PrCheckViolation(
      check: 'gfm-alert-format',
      message:
          '$relPath:$lineNumber has inline text on the same line as a GitHub '
          'Alert marker (> [!TYPE] ...), which renders as a plain blockquote '
          'on GitHub.',
      remediation:
          'Place > [!TYPE] on its own line followed by an empty blockquote '
          'line (>), or run `mdf $relPath`.',
    );
  }
  if (_gfmAlertHeaderRegex.hasMatch(line) &&
      (nextLine == null ||
          nextLine.trim() != '>' ||
          bodyLine == null ||
          !_gfmAlertBodyLineRegex.hasMatch(bodyLine))) {
    return PrCheckViolation(
      check: 'gfm-alert-format',
      message:
          '$relPath:$lineNumber is missing an empty blockquote line (>) and '
          'blockquote body line (> ...) after > [!TYPE], which Prettier '
          '(--prose-wrap always) collapses onto one line.',
      remediation:
          'Insert an empty `>` line followed by `> <body text>` after '
          '`> [!TYPE]`, or run `mdf $relPath`.',
    );
  }
  if (_google3DirectiveRegex.hasMatch(line)) {
    return PrCheckViolation(
      check: 'gfm-no-google3-directives',
      message:
          '$relPath:$lineNumber contains a Google3-only Markdown directive '
          '(`<!-- mdformat ... -->` or `[TOC]`).',
      remediation:
          'Remove `<!-- mdformat ... -->` and `[TOC]` directives from '
          'GitHub Markdown files.',
    );
  }
  return _checkInlineCodeFlagDashes(relPath, lineNumber, line);
}
