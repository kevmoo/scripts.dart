import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_util/cli_util.dart';
import 'package:firehose/firehose.dart' as firehose;
import 'package:io/ansi.dart' as ansi;
import 'package:io/io.dart';
import 'package:path/path.dart' as p;

import 'process_utils.dart';
import 'shared/gh_args.dart';
import 'testable_print.dart';

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

/// Summary of a `pr-check` run against a repository worktree.
final class PrCheckReport {
  final String baseRef;
  final List<String> changedFiles;
  final List<PrCheckViolation> violations;

  const new({
    required this.baseRef,
    required this.changedFiles,
    required this.violations,
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
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this usage information.',
  );

/// Entrypoint for `pr-check` and `kscripts pr-check`.
Future<void> runPrCheckCli(
  List<String> args, {
  SyncProcessRunner processRunner = defaultSyncProcessRunner,
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

  final report = runPrCheck(
    directory: targetDir,
    baseRefOverride: results['base'] as String?,
    requireWip: results['require-wip'] as bool,
    processRunner: processRunner,
  );

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
  return buf.toString().trimRight();
}

/// Runs all deterministic pre-PR checks on [directory].
PrCheckReport runPrCheck({
  required Directory directory,
  String? baseRefOverride,
  bool requireWip = true,
  SyncProcessRunner processRunner = defaultSyncProcessRunner,
}) {
  final repoRoot = _resolveGitTopLevel(directory, processRunner) ?? directory;
  final violations = <PrCheckViolation>[];

  final dirtyViolation = _checkCleanWorkingTree(repoRoot, processRunner);
  if (dirtyViolation != null) {
    violations.add(dirtyViolation);
  }

  final baseRef = _resolveBaseRef(repoRoot, baseRefOverride, processRunner);
  final changedFiles = _collectChangedFiles(repoRoot, baseRef, processRunner);
  if (changedFiles.isEmpty) {
    return PrCheckReport(
      baseRef: baseRef,
      changedFiles: changedFiles,
      violations: violations,
    );
  }

  final workflowsText = _readWorkflowsContent(repoRoot);
  final dartBin = _resolveDartBinary();

  violations.addAll(
    _checkFirehosePackages(
      repoRoot: repoRoot,
      baseRef: baseRef,
      changedFiles: changedFiles.toSet(),
      requireWip: requireWip,
      runSync: processRunner,
    ),
  );

  final dartFiles = changedFiles.where((f) => f.endsWith('.dart')).toList();
  if (dartFiles.isNotEmpty && !_isDartSdkRepo(repoRoot)) {
    final fmtViolation = _checkDartFormat(
      repoRoot,
      dartFiles,
      dartBin,
      processRunner,
    );
    if (fmtViolation != null) violations.add(fmtViolation);

    final analyzeViolation = _checkDartAnalyzeFatalInfos(
      repoRoot,
      dartFiles,
      dartBin,
      processRunner,
    );
    if (analyzeViolation != null) violations.add(analyzeViolation);

    final ccViolation = _checkCognitiveComplexity(
      repoRoot,
      dartFiles,
      workflowsText,
      dartBin,
      processRunner,
    );
    if (ccViolation != null) violations.add(ccViolation);

    violations.addAll(
      _checkBrowserTestOnVm(repoRoot, dartFiles, workflowsText),
    );
  }

  final mdFiles = changedFiles.where((f) => f.endsWith('.md')).toList();
  if (mdFiles.isNotEmpty) {
    violations.addAll(_checkGitHubMarkdownConventions(repoRoot, mdFiles));
    final prettierViolation = _checkPrettierMarkdown(
      repoRoot,
      mdFiles,
      workflowsText,
      processRunner,
    );
    if (prettierViolation != null) violations.add(prettierViolation);
  }

  return PrCheckReport(
    baseRef: baseRef,
    changedFiles: changedFiles,
    violations: violations,
  );
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

bool _isDartSdkRepo(Directory repoRoot) =>
    File(p.join(repoRoot.path, 'tools', 'VERSION')).existsSync();

/// Validates publishable packages using `package:firehose` (`Repository`,
/// `Package`, and `Changelog`).
List<PrCheckViolation> _checkFirehosePackages({
  required Directory repoRoot,
  required String baseRef,
  required Set<String> changedFiles,
  required bool requireWip,
  required SyncProcessRunner runSync,
}) {
  final packages = runZoned(
    () => firehose.Repository(repoRoot).locatePackages(),
    zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
  );
  final violations = <PrCheckViolation>[];
  for (final pkg in packages) {
    final v = _validateSingleFirehosePackage(
      repoRoot: repoRoot,
      baseRef: baseRef,
      pkg: pkg,
      changedFiles: changedFiles,
      requireWip: requireWip,
      runSync: runSync,
    );
    violations.addAll(v);
  }
  return violations;
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
  final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(out);
  return match?.group(1);
}

List<PrCheckViolation> _validateSingleFirehosePackage({
  required Directory repoRoot,
  required String baseRef,
  required firehose.Package pkg,
  required Set<String> changedFiles,
  required bool requireWip,
  required SyncProcessRunner runSync,
}) {
  final relDir = p.relative(pkg.directory.path, from: repoRoot.path);
  final prefix = relDir == '.' ? '' : '$relDir/';
  final pkgChangedFiles = _packageRelativeChanges(prefix, changedFiles);
  if (pkgChangedFiles.isEmpty) return const [];

  final violations = <PrCheckViolation>[];
  final ver = pkg.version;
  if (ver == null) return violations;
  final verStr = ver.toString();

  final changelogVer = pkg.changelog.latestVersion;
  if (pkg.changelog.exists && changelogVer != verStr) {
    violations.add(
      PrCheckViolation(
        check: 'firehose-changelog',
        message:
            'package:${pkg.name} pubspec.yaml version ($verStr) does not '
            'match CHANGELOG.md top entry ($changelogVer).',
        remediation:
            'Prepend "## $verStr" to ${p.join(relDir, 'CHANGELOG.md')} '
            'or align pubspec.yaml.',
      ),
    );
  }

  final versionDart = File(
    p.join(pkg.directory.path, 'lib', 'src', 'version.dart'),
  );
  if (versionDart.existsSync() &&
      !versionDart.readAsStringSync().contains(verStr)) {
    final relVerPath = p.join(relDir, 'lib/src/version.dart');
    violations.add(
      PrCheckViolation(
        check: 'version-dart-sync',
        message:
            'package:${pkg.name} is at $verStr, but '
            '$relVerPath does not contain $verStr.',
        remediation: 'Regenerate or update $relVerPath to match $verStr.',
      ),
    );
  }

  final pubspecRel = prefix.isEmpty ? 'pubspec.yaml' : '${prefix}pubspec.yaml';
  final touchesPackageSurface = pkgChangedFiles.any(_isCodeOrPackageFile);
  final baseVer = _readBasePubspecVersion(
    repoRoot,
    baseRef,
    pubspecRel,
    runSync,
  );
  if (requireWip &&
      touchesPackageSurface &&
      !ver.isPreRelease &&
      (baseVer == null || baseVer == verStr)) {
    final nextWip = '${ver.major}.${ver.minor}.${ver.patch + 1}-wip';
    violations.add(
      PrCheckViolation(
        check: 'pubspec-wip-bump',
        message:
            'package:${pkg.name} is at released version $verStr without a '
            '-wip bump in $pubspecRel.',
        remediation:
            'Bump $pubspecRel to "version: $nextWip" and add "## $nextWip" '
            'to ${p.join(relDir, 'CHANGELOG.md')}.',
      ),
    );
  }

  return violations;
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
  List<String> dartFiles,
  String workflowsText,
  String dartBin,
  SyncProcessRunner runSync,
) {
  if (!workflowsText.contains('cognitive_complexity')) return null;
  final libBinFiles = dartFiles.where(_isLibOrBinDartFile).toList();
  if (libBinFiles.isEmpty) return null;

  final home = Platform.environment['HOME'] ?? '';
  final ccScript = File(
    p.join(
      home,
      'github',
      'kevmoo',
      'analytica.dart',
      'packages',
      'cognitive_complexity',
      'bin',
      'cognitive_complexity.dart',
    ),
  );
  if (!ccScript.existsSync()) return null;

  final res = runSync(dartBin, [
    ccScript.path,
    '--fail-threshold',
    '15',
    ...libBinFiles,
  ], workingDirectory: repoRoot.path);
  if (res.exitCode == 0) return null;
  return PrCheckViolation(
    check: 'cognitive-complexity',
    message:
        'Repository CI enforces cognitive_complexity <= 15, which failed:\n'
        '${(res.stdout as String).trim()}',
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
  List<String> dartFiles,
  String workflowsText,
) {
  if (!RegExp(r'\b(chrome|wasm|firefox)\b').hasMatch(workflowsText)) {
    return const [];
  }
  final violations = <PrCheckViolation>[];
  final ioImportRegex = RegExp(r'''import\s+['"]dart:(io|ffi)['"]''');
  final testOnVmRegex = RegExp(r'''@TestOn\(\s*['"]vm['"]\s*\)''');

  for (final relPath in dartFiles) {
    if (!relPath.endsWith('_test.dart')) continue;
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
  String workflowsText,
  SyncProcessRunner runSync,
) {
  final hasPrettier =
      workflowsText.toLowerCase().contains('prettier') ||
      File(p.join(repoRoot.path, '.prettierrc.json')).existsSync();
  if (!hasPrettier) return null;

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

final _gfmAlertInlineRegex = RegExp(
  r'^\s*>\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s+\S',
);
final _gfmAlertHeaderRegex = RegExp(
  r'^\s*>\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$',
);
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
/// conventions (Prettier-safe GFM alerts with an empty `>` separator line, and
/// no Google3-only `<!-- mdformat ... -->` or `[TOC]` directives).
List<PrCheckViolation> checkGitHubMarkdownLines(
  String relPath,
  List<String> lines,
) {
  final violations = <PrCheckViolation>[];
  String? activeFence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final nextFence = _updateFenceState(activeFence, line);
    if (activeFence != null || nextFence != null) {
      activeFence = nextFence;
      continue;
    }
    final nextLine = i + 1 < lines.length ? lines[i + 1] : null;
    final violation = _checkSingleMarkdownLine(relPath, i + 1, line, nextLine);
    if (violation != null) violations.add(violation);
  }
  return violations;
}

String? _updateFenceState(String? activeFence, String line) {
  final match = RegExp(r'^\s*(`{3,}|~{3,})(.*)$').firstMatch(line);
  if (match == null) return activeFence;
  final fence = match.group(1)!;
  if (activeFence == null) return fence;
  final isClosing =
      fence.startsWith(activeFence) && match.group(2)!.trim().isEmpty;
  return isClosing ? null : activeFence;
}

PrCheckViolation? _checkSingleMarkdownLine(
  String relPath,
  int lineNumber,
  String line,
  String? nextLine,
) {
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
      nextLine != null &&
      nextLine.trim() != '>') {
    return PrCheckViolation(
      check: 'gfm-alert-format',
      message:
          '$relPath:$lineNumber is missing an empty blockquote line (>) after '
          '> [!TYPE], which Prettier (--prose-wrap always) collapses onto '
          'one line.',
      remediation:
          'Insert an empty `>` line immediately after `> [!TYPE]`, or run '
          '`mdf $relPath`.',
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
  return null;
}
