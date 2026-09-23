import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'relay_whoami/relay_models.dart';
import 'testable_print.dart';

export 'relay_whoami/relay_models.dart';

/// Top-level description for `kscripts relay-whoami --help`.
const relayWhoamiDescription =
    'Cross-machine agent relay identity, envelope, and sync status checker.';

/// Detected machine persona and environment configuration for `/relay`.
final class RelayEnvironment {
  final String moniker;
  final String slug;
  final String matchPattern;
  final String hostShort;
  final String archTag;
  final String defaultTo;
  final String nowPt;
  final String nowUtc;
  final String sessionShort;
  final String workspace;
  final String publicGithubRepo;
  final String corpRepo;
  final String corpDir;
  final String ossRepo;
  final String ossDir;
  final bool hasGgh;
  final bool hasGh;

  const new({
    required this.moniker,
    required this.slug,
    required this.matchPattern,
    required this.hostShort,
    required this.archTag,
    required this.defaultTo,
    required this.nowPt,
    required this.nowUtc,
    required this.sessionShort,
    required this.workspace,
    required this.publicGithubRepo,
    required this.corpRepo,
    required this.corpDir,
    required this.ossRepo,
    required this.ossDir,
    required this.hasGgh,
    required this.hasGh,
  });

  /// Formats the Markdown envelope header block.
  String formatHeader({
    required String toTarget,
    required String threadLabel,
    required String stateTag,
    required String channelResolved,
    required String classification,
    String? repoOverride,
    String? modelOverride,
  }) {
    final modelSegment =
        (modelOverride != null && modelOverride.trim().isNotEmpty)
        ? ' · **Model**: `${modelOverride.trim()}`'
        : '';
    if (channelResolved == 'oss') {
      final repoTag = _firstNonEmpty([repoOverride, publicGithubRepo, ossRepo]);
      return '### $moniker (`$hostShort` · `$archTag`) → $toTarget\n'
          '> **Thread**: `$threadLabel` | **State**: `$stateTag` | '
          '**Time**: `$nowPt`\n'
          '> **Repo**: `$repoTag`$modelSegment · '
          '**Session**: `$sessionShort` · '
          '**Classification**: `$classification`';
    }
    final wsTag = _firstNonEmpty([repoOverride, workspace]);
    return '### $moniker (`$hostShort` · `$archTag`) → $toTarget\n'
        '> **Thread**: `$threadLabel` | **State**: `$stateTag` | '
        '**Time**: `$nowPt`\n'
        '> **Workspace**: `$wsTag`$modelSegment · '
        '**Session**: `$sessionShort` · '
        '**Classification**: `$classification`';
  }
}

/// Parsed CLI options for `relay-whoami`.
final class RelayWhoamiOptions {
  final String mode;
  final bool saveSync;
  final bool resetSync;
  final bool help;
  final String? toTarget;
  final String threadLabel;
  final String stateTag;
  final String channel;
  final String repoOverride;
  final String modelOverride;

  const new({
    required this.mode,
    required this.saveSync,
    required this.resetSync,
    required this.help,
    required this.toTarget,
    required this.threadLabel,
    required this.stateTag,
    required this.channel,
    required this.repoOverride,
    required this.modelOverride,
  });

  static ArgParser createArgParser() => ArgParser()
    ..addFlag(
      'check',
      negatable: false,
      help:
          'Sync relay git repos, show git/issue deltas since last sync, '
          'and highlight inbound action items.',
    )
    ..addFlag(
      'header',
      negatable: false,
      help: 'Emit only the Markdown message envelope header.',
    )
    ..addFlag(
      'save',
      defaultsTo: true,
      help: 'Update the sync watermark after --check.',
    )
    ..addFlag(
      'dry-run',
      negatable: false,
      help: 'Alias for --no-save (preview deltas without updating watermark).',
    )
    ..addFlag(
      'reset-sync',
      negatable: false,
      help: 'Reset sync watermark before evaluating.',
    )
    ..addOption('to', help: 'Recipient moniker(s) for --header.')
    ..addOption(
      'thread',
      defaultsTo: '#<N> <topic>',
      help: 'Thread number and short title for --header.',
    )
    ..addOption(
      'state',
      defaultsTo: 'HANDOFF',
      help: 'Envelope state tag (HANDOFF | REPORT | ACKED).',
    )
    ..addOption(
      'channel',
      defaultsTo: 'auto',
      allowed: const ['auto', 'corp', 'oss'],
      help: 'Target relay channel (corp or oss).',
    )
    ..addOption(
      'repo',
      defaultsTo: '',
      help: 'Explicit repository tag for PUBLIC_SAFE_OSS headers.',
    )
    ..addOption('model', help: 'Optional LLM model identifier tag.')
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );
}

/// Parses [args] into [RelayWhoamiOptions] via `package:args`, throwing
/// [FormatException] with prescriptive failure hints on invalid invocations.
RelayWhoamiOptions parseRelayWhoamiArgs(
  List<String> args, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  for (final arg in args) {
    if (arg == 'check' || arg == 'status' || arg == '--sync' || arg == 'sync') {
      throw FormatException(
        "Error: Unknown subcommand '$arg'. "
        "Did you mean 'relay-whoami --check'?",
      );
    }
    if (arg == 'header') {
      throw FormatException(
        "Error: Unknown subcommand '$arg'. "
        "Did you mean 'relay-whoami --header'?",
      );
    }
  }

  final parser = RelayWhoamiOptions.createArgParser();
  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    throw FormatException(
      "Error: ${e.message} Run 'relay-whoami --help' for usage.",
    );
  }

  if (results.rest.isNotEmpty) {
    throw FormatException(
      "Error: Unexpected positional argument '${results.rest.first}'. "
      "Run 'relay-whoami --help' for usage.",
    );
  }

  final isCheck = results['check'] as bool;
  final isHeader = results['header'] as bool;
  final mode = isHeader
      ? 'header'
      : isCheck
      ? 'check'
      : 'info';
  final saveSync = (results['save'] as bool) && !(results['dry-run'] as bool);

  return RelayWhoamiOptions(
    mode: mode,
    saveSync: saveSync,
    resetSync: results['reset-sync'] as bool,
    help: results['help'] as bool,
    toTarget: results['to'] as String?,
    threadLabel: results['thread'] as String,
    stateTag: results['state'] as String,
    channel: results['channel'] as String,
    repoOverride: results['repo'] as String,
    modelOverride:
        (results['model'] as String?) ??
        env['ANTIGRAVITY_MODEL'] ??
        env['CLAUDE_MODEL'] ??
        '',
  );
}

/// Entrypoint for `kscripts relay-whoami`.
Future<void> runRelayWhoamiCli(List<String> args) async {
  RelayWhoamiOptions options;
  try {
    options = parseRelayWhoamiArgs(args);
  } on FormatException catch (e) {
    setError(message: e.message, exitCode: 2);
    return;
  }

  if (options.help) {
    print(relayWhoamiDescription);
    print('');
    print('Usage: relay-whoami [--check | --header] [options]');
    print('');
    print(RelayWhoamiOptions.createArgParser().usage);
    return;
  }

  final env = await detectRelayEnvironment();
  final resolvedChannel = _resolveChannel(options.channel, env);

  if (options.mode == 'header') {
    print(
      env.formatHeader(
        toTarget: options.toTarget ?? env.defaultTo,
        threadLabel: options.threadLabel,
        stateTag: options.stateTag,
        channelResolved: resolvedChannel.channel,
        classification: resolvedChannel.classification,
        repoOverride: options.repoOverride,
        modelOverride: options.modelOverride,
      ),
    );
    return;
  }

  if (options.mode == 'check') {
    await _runRelayCheck(env, options);
    return;
  }

  final header = env.formatHeader(
    toTarget: options.toTarget ?? env.defaultTo,
    threadLabel: options.threadLabel,
    stateTag: options.stateTag,
    channelResolved: resolvedChannel.channel,
    classification: resolvedChannel.classification,
    repoOverride: options.repoOverride,
    modelOverride: options.modelOverride,
  );

  print('PERSONA="${env.moniker}"');
  print('SLUG="${env.slug}"');
  print('HOST="${env.hostShort}"');
  print('ARCH="${env.archTag}"');
  print('TIME_PT="${env.nowPt}"');
  print('SESSION="${env.sessionShort}"');
  print('WORKSPACE="${env.workspace}"');
  print('HAS_CORP_FOG_GGH="${env.hasGgh}"');
  print('HAS_OSS_GITHUB_GH="${env.hasGh}"');
  print('');
  print('--- Markdown Envelope ---');
  print(header);
}

({String channel, String classification}) _resolveChannel(
  String requested,
  RelayEnvironment env,
) {
  if (requested == 'corp') {
    return (channel: 'corp', classification: 'CORP_PRIVATE');
  }
  if (requested == 'oss') {
    return (channel: 'oss', classification: 'PUBLIC_SAFE_OSS');
  }
  if (env.hasGgh && env.corpRepo.isNotEmpty) {
    return (
      channel: 'corp',
      classification: 'CORP_PRIVATE (or PUBLIC_SAFE_OSS on GitHub)',
    );
  }
  return (channel: 'oss', classification: 'PUBLIC_SAFE_OSS');
}

/// Detects the current machine persona, available CLIs (`ggh`, `gh`), and
/// repository paths without any hardcoded corporate strings.
Future<RelayEnvironment> detectRelayEnvironment() async {
  final sysEnv = Platform.environment;
  final home = sysEnv['HOME'] ?? '';
  final unameM = await _runCapture('uname', const ['-m']) ?? 'x86_64';
  final rawHost = sysEnv['HOSTNAME'] ?? Platform.localHostname;
  final hostShort = rawHost.split('.').first;

  final nowPt =
      await _runCapture(
        'date',
        const ['+%Y-%m-%d %H:%M PT'],
        environment: const {'TZ': 'America/Los_Angeles'},
      ) ??
      DateTime.now().toIso8601String();
  final nowUtc = DateTime.now().toUtc().toIso8601String().replaceFirst(
    RegExp(r'\.\d+Z$'),
    'Z',
  );

  final hasGgh = await _commandExists('ggh');
  final hasGh = await _commandExists('gh');
  final corpConfig = await _resolveCorpRelayConfig(sysEnv, home);
  final ossRepo = sysEnv['AGENT_RELAY_OSS_REPO'] ?? 'kevmoo/agent-relay';
  final ossDir =
      sysEnv['AGENT_RELAY_OSS_DIR'] ??
      p.join(home, 'github/kevmoo/agent-relay');

  final persona = _classifyPersona(
    isMacOS: Platform.isMacOS,
    unameM: unameM,
    hasGgh: hasGgh,
    corpRepo: corpConfig.repo,
  );

  final rawSession =
      sysEnv['ANTIGRAVITY_CONVERSATION_ID'] ??
      sysEnv['CLAUDE_CODE_SESSION_ID'] ??
      sysEnv['CLAUDE_SESSION_ID'] ??
      'local';
  final sessionShort = rawSession.length > 8
      ? rawSession.substring(0, 8)
      : rawSession;

  final wsInfo = await _detectWorkspaceInfo();

  return RelayEnvironment(
    moniker: persona.moniker,
    slug: persona.slug,
    matchPattern: persona.matchPattern,
    hostShort: hostShort,
    archTag: persona.archTag,
    defaultTo: persona.defaultTo,
    nowPt: nowPt,
    nowUtc: nowUtc,
    sessionShort: sessionShort,
    workspace: wsInfo.workspace,
    publicGithubRepo: wsInfo.publicGithubRepo,
    corpRepo: corpConfig.repo,
    corpDir: corpConfig.dir,
    ossRepo: ossRepo,
    ossDir: ossDir,
    hasGgh: hasGgh,
    hasGh: hasGh,
  );
}

({
  String moniker,
  String slug,
  String matchPattern,
  String archTag,
  String defaultTo,
})
_classifyPersona({
  required bool isMacOS,
  required String unameM,
  required bool hasGgh,
  required String corpRepo,
}) {
  if (isMacOS) {
    return (
      moniker: '🍎🏎️✨ Darwin Pro',
      slug: 'darwin-pro',
      matchPattern: 'Darwin Pro|darwin-pro|gmac',
      archTag: 'macos_$unameM',
      defaultTo: '☁️🐧⚡ Enterprise Rodete',
    );
  }
  final osRelease = _readOsReleaseText();
  if (File('/run/ostree-booted').existsSync() ||
      osRelease.contains('bluefin')) {
    return (
      moniker: '🐧🛠️🐳 Bluefin-DX',
      slug: 'bluefin-dx',
      matchPattern: 'Bluefin-DX|bluefin-dx|bluefin',
      archTag: 'linux_$unameM',
      defaultTo: '☁️🐧⚡ Enterprise Rodete, 🍎🏎️✨ Darwin Pro',
    );
  }
  if (osRelease.contains('rodete') || hasGgh || corpRepo.isNotEmpty) {
    return (
      moniker: '☁️🐧⚡ Enterprise Rodete',
      slug: 'enterprise-rodete',
      matchPattern: 'Enterprise Rodete|enterprise-rodete|Cloudtop',
      archTag: 'linux_$unameM',
      defaultTo: '🍎🏎️✨ Darwin Pro',
    );
  }
  return (
    moniker: '❓ Unknown Linux Host',
    slug: 'unknown-linux',
    matchPattern: 'Unknown Linux|unknown-linux',
    archTag: 'linux_$unameM',
    defaultTo: '☁️🐧⚡ Enterprise Rodete',
  );
}

String _readOsReleaseText() {
  final buf = StringBuffer();
  for (final path in const ['/etc/os-release', '/run/host/etc/os-release']) {
    final file = File(path);
    if (file.existsSync()) {
      try {
        buf.writeln(file.readAsStringSync().toLowerCase());
      } catch (_) {}
    }
  }
  return buf.toString();
}

Future<({String repo, String dir})> _resolveCorpRelayConfig(
  Map<String, String> env,
  String home,
) async {
  var repo = env['AGENT_RELAY_CORP_REPO'] ?? '';
  var dir = env['AGENT_RELAY_CORP_DIR'] ?? '';

  if (repo.isEmpty || dir.isEmpty) {
    final fromZsh = _readLocalZshRelayConfig(home);
    if (repo.isEmpty) repo = fromZsh.repo;
    if (dir.isEmpty) dir = fromZsh.dir;
  }

  if (repo.isEmpty || dir.isEmpty) {
    final fromFog = await _discoverFogRelayClone(home);
    if (repo.isEmpty) repo = fromFog.repo;
    if (dir.isEmpty) dir = fromFog.dir;
  }

  if (repo.endsWith('.git')) {
    repo = repo.substring(0, repo.length - 4);
  }
  return (repo: repo, dir: dir);
}

({String repo, String dir}) _readLocalZshRelayConfig(String home) {
  final localZsh = File(p.join(home, '.config/zsh/rc.d/local.zsh'));
  if (!localZsh.existsSync()) return (repo: '', dir: '');
  try {
    final text = localZsh.readAsStringSync();
    final repo =
        RegExp(
          r'^export AGENT_RELAY_CORP_REPO="([^"]+)"',
          multiLine: true,
        ).firstMatch(text)?.group(1) ??
        '';
    final rawDir =
        RegExp(
          r'^export AGENT_RELAY_CORP_DIR="([^"]+)"',
          multiLine: true,
        ).firstMatch(text)?.group(1) ??
        '';
    return (repo: repo, dir: rawDir.replaceAll(r'$HOME', home));
  } catch (_) {
    return (repo: '', dir: '');
  }
}

Future<({String repo, String dir})> _discoverFogRelayClone(String home) async {
  final fogDir = Directory(p.join(home, 'fog'));
  if (!fogDir.existsSync()) return (repo: '', dir: '');
  for (final entity in fogDir.listSync().whereType<Directory>()) {
    if (!entity.path.endsWith('-relay') ||
        !Directory(p.join(entity.path, '.git')).existsSync()) {
      continue;
    }
    final remote = await _runCapture('git', [
      '-C',
      entity.path,
      'remote',
      'get-url',
      'origin',
    ]);
    final match = RegExp(r'[:/]([^/:]+/[^/:]+?)(\.git)?$')
        .firstMatch(remote ?? '');
    return (repo: match?.group(1) ?? '', dir: entity.path);
  }
  return (repo: '', dir: '');
}

Future<({String workspace, String publicGithubRepo})>
_detectWorkspaceInfo() async {
  final cwdName = p.basename(Directory.current.path);
  final insideGit = await _runCapture('git', const [
    'rev-parse',
    '--is-inside-work-tree',
  ]);
  if (insideGit != 'true') {
    return (workspace: cwdName, publicGithubRepo: '');
  }
  final topLevel =
      await _runCapture('git', const ['rev-parse', '--show-toplevel']) ??
      Directory.current.path;
  final repoRoot = p.basename(topLevel);
  final branch =
      await _runCapture('git', const ['rev-parse', '--abbrev-ref', 'HEAD']) ??
      'HEAD';
  final sha =
      await _runCapture('git', const ['rev-parse', '--short', 'HEAD']) ?? '';
  final shaSuffix = sha.isNotEmpty ? ' @ $sha' : '';
  final workspace = '$repoRoot ($branch$shaSuffix)';

  final originUrl =
      await _runCapture('git', const ['remote', 'get-url', 'origin']) ?? '';
  final ghMatch = RegExp(r'github\.com[:/]([^/:]+/[^/:]+?)(\.git)?$')
      .firstMatch(originUrl);
  final publicRepo = ghMatch != null ? '${ghMatch.group(1)!}$shaSuffix' : '';

  return (workspace: workspace, publicGithubRepo: publicRepo);
}

Future<void> _runRelayCheck(
  RelayEnvironment env,
  RelayWhoamiOptions options,
) async {
  final home = Platform.environment['HOME'] ?? '';
  final stateDir = Directory(
    p.join(
      Platform.environment['XDG_STATE_HOME'] ?? p.join(home, '.local/state'),
      'agent-relay',
    ),
  )..createSync(recursive: true);
  final stateFile = File(p.join(stateDir.path, 'sync_state.json'));

  final prevState = _loadPreviousSyncState(
    stateFile,
    resetSync: options.resetSync,
  );
  final lastSyncPt = (prevState['last_sync_pt'] ?? 'initial sync').toString();
  final prevCorpSha = ((prevState['corp'] as Map?)?['git_head'] ?? '')
      .toString();
  final prevOssSha = ((prevState['oss'] as Map?)?['git_head'] ?? '').toString();

  // Execute all 4 git + issue sync tasks concurrently via Future.wait.
  final corpGitFuture = (env.hasGgh && env.corpRepo.isNotEmpty)
      ? _syncGitRepo(
          label: '🔒 Corp Relay (${env.corpRepo})',
          dir: env.corpDir,
          prevSha: prevCorpSha,
          home: home,
        )
      : Future.value((
          lines: const ['  ⚪ 🔒 Corp Relay: N/A on this host'],
          afterSha: '',
        ));

  final ossGitFuture = env.hasGh
      ? _syncGitRepo(
          label: '🌐 GitHub Relay (${env.ossRepo})',
          dir: env.ossDir,
          prevSha: prevOssSha,
          home: home,
        )
      : Future.value((lines: const <String>[], afterSha: ''));

  final corpIssuesFuture = (env.hasGgh && env.corpRepo.isNotEmpty)
      ? _fetchChannelIssues('ggh', env.corpRepo)
      : Future.value((
          issues: const <RelayIssueRaw>[],
          ok: 'skipped',
          error: '',
        ));

  final ossIssuesFuture = env.hasGh
      ? _fetchChannelIssues('gh', env.ossRepo)
      : Future.value((
          issues: const <RelayIssueRaw>[],
          ok: 'skipped',
          error: '',
        ));

  final results = await Future.wait([
    corpGitFuture,
    ossGitFuture,
    corpIssuesFuture,
    ossIssuesFuture,
  ]);

  final corpGit = results[0] as ({List<String> lines, String afterSha});
  final ossGit = results[1] as ({List<String> lines, String afterSha});
  final corpIssues =
      results[2] as ({List<RelayIssueRaw> issues, String ok, String error});
  final ossIssues =
      results[3] as ({List<RelayIssueRaw> issues, String ok, String error});

  print(
    '📟 Active Persona: ${env.moniker} '
    '(${env.hostShort} · ${env.archTag}) | ${env.nowPt}',
  );
  print('🔄 Last Sync Watermark: $lastSyncPt');
  print('');
  print('=== 📦 1. Git Repository Sync & Deltas (since $lastSyncPt) ===');
  for (final line in [...corpGit.lines, ...ossGit.lines]) {
    print(line);
  }
  print('');

  final selfPattern = RegExp(env.matchPattern, caseSensitive: false);
  final corpEnriched = corpIssues.issues
      .map(
        (r) => EnrichedRelayIssue.fromRaw(
          r,
          channel: 'corp',
          repo: env.corpRepo,
          selfPattern: selfPattern,
        ),
      )
      .toList();
  final ossEnriched = ossIssues.issues
      .map(
        (r) => EnrichedRelayIssue.fromRaw(
          r,
          channel: 'oss',
          repo: env.ossRepo,
          selfPattern: selfPattern,
        ),
      )
      .toList();

  final built = buildRelayCheckReport(
    moniker: env.moniker,
    lastSyncPt: lastSyncPt,
    nowUtc: env.nowUtc,
    nowPt: env.nowPt,
    corpRepo: env.corpRepo.isNotEmpty ? env.corpRepo : 'corp',
    ossRepo: env.ossRepo,
    corpOk: corpIssues.ok,
    corpErr: corpIssues.error,
    ossOk: ossIssues.ok,
    ossErr: ossIssues.error,
    newCorpSha: corpGit.afterSha,
    newOssSha: ossGit.afterSha,
    prevState: prevState,
    corpEnriched: corpEnriched,
    ossEnriched: ossEnriched,
  );

  print(built.report);
  print('');

  if (options.saveSync) {
    final encoded = const JsonEncoder.withIndent('  ').convert(built.newState);
    File('${stateFile.path}.tmp.$pid')
      ..writeAsStringSync('$encoded\n')
      ..renameSync(stateFile.path);
  }
}

Map<String, Object?> _loadPreviousSyncState(
  File stateFile, {
  required bool resetSync,
}) {
  const defaultState = <String, Object?>{
    'last_sync_utc': '',
    'last_sync_pt': 'initial sync',
    'corp': {'git_head': '', 'issues': <String, Object?>{}},
    'oss': {'git_head': '', 'issues': <String, Object?>{}},
  };
  if (resetSync || !stateFile.existsSync()) return defaultState;
  try {
    final decoded = jsonDecode(stateFile.readAsStringSync());
    if (decoded is Map<String, Object?>) return decoded;
  } catch (_) {}
  stderr.writeln(
    '⚠️  Sync watermark unreadable (${stateFile.path}); '
    'starting fresh (or pass --reset-sync).',
  );
  return defaultState;
}

Future<({List<String> lines, String afterSha})> _syncGitRepo({
  required String label,
  required String dir,
  required String prevSha,
  required String home,
}) async {
  if (dir.isEmpty || !Directory(p.join(dir, '.git')).existsSync()) {
    return (
      lines: [
        '  ⚪ $label: local clone not present (${dir.isEmpty ? 'unset' : dir})',
      ],
      afterSha: '',
    );
  }
  final shortDir = home.isNotEmpty && dir.startsWith(home)
      ? '~${dir.substring(home.length)}'
      : dir;
  final beforeSha =
      await _runCapture('git', ['-C', dir, 'rev-parse', 'HEAD']) ?? '';
  final effectivePrev = prevSha.isNotEmpty ? prevSha : beforeSha;

  await Process.run(
    'git',
    ['-C', dir, 'fetch', 'origin', '--quiet'],
    environment: const {'GIT_TERMINAL_PROMPT': '0'},
  );

  final dirty =
      await _runCapture('git', ['-C', dir, 'status', '--porcelain']) ?? '';
  final branch =
      await _runCapture('git', [
        '-C',
        dir,
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ]) ??
      'HEAD';

  if (dirty.isEmpty && branch == 'main') {
    await Process.run('git', [
      '-C',
      dir,
      'merge',
      '--ff-only',
      'origin/main',
      '--quiet',
    ]);
  }

  final afterSha =
      await _runCapture('git', ['-C', dir, 'rev-parse', 'HEAD']) ?? '';
  final lines = await _formatGitCommitDeltas(
    label: label,
    dir: dir,
    shortDir: shortDir,
    effectivePrev: effectivePrev,
    afterSha: afterSha,
  );

  if (dirty.isNotEmpty) {
    lines.add('  ⚠️  $label ($shortDir) has uncommitted local changes:');
    for (final l in dirty.split('\n').where((s) => s.trim().isNotEmpty)) {
      lines.add('     $l');
    }
  }

  return (lines: lines, afterSha: afterSha);
}

String _shortSha(String sha) => sha.length >= 7 ? sha.substring(0, 7) : sha;

Future<List<String>> _formatGitCommitDeltas({
  required String label,
  required String dir,
  required String shortDir,
  required String effectivePrev,
  required String afterSha,
}) async {
  final shortAfter = _shortSha(afterSha);
  final hasPrevCommit =
      effectivePrev.isNotEmpty &&
      effectivePrev != afterSha &&
      (await Process.run('git', [
            '-C',
            dir,
            'cat-file',
            '-e',
            '$effectivePrev^{commit}',
          ])).exitCode ==
          0;

  if (!hasPrevCommit) {
    final msg =
        '  ✅ $label ($shortDir): up to date at $shortAfter '
        '(0 new commits since last sync)';
    return [msg];
  }

  final shortPrev = _shortSha(effectivePrev);
  final count =
      await _runCapture('git', [
        '-C',
        dir,
        'rev-list',
        '--count',
        '$effectivePrev..$afterSha',
      ]) ??
      '?';
  final logOut =
      await _runCapture('git', [
        '-C',
        dir,
        'log',
        '--oneline',
        '$effectivePrev..$afterSha',
      ]) ??
      '';
  final summary =
      '  🆕 $label ($shortDir): '
      '+$count new commit(s) ($shortPrev..$shortAfter)';
  return [
    summary,
    for (final l in logOut.split('\n').where((s) => s.trim().isNotEmpty))
      '     • $l',
  ];
}

Future<({List<RelayIssueRaw> issues, String ok, String error})>
_fetchChannelIssues(String cli, String repo) async {
  const fields = 'number,title,state,updatedAt,createdAt,url,body,comments';
  final results = await Future.wait([
    Process.run(cli, [
      'issue',
      'list',
      '-R',
      repo,
      '--state',
      'open',
      '--limit',
      '50',
      '--json',
      fields,
    ]),
    Process.run(cli, [
      'issue',
      'list',
      '-R',
      repo,
      '--state',
      'closed',
      '--limit',
      '15',
      '--json',
      fields,
    ]),
  ]);

  for (final res in results) {
    if (res.exitCode != 0) {
      final errText = '${res.stderr}\n${res.stdout}'.trim();
      final firstLine = errText.split('\n').first;
      return (issues: const <RelayIssueRaw>[], ok: 'false', error: firstLine);
    }
  }

  try {
    final openList = jsonDecode(results[0].stdout.toString()) as List<Object?>;
    final closedList =
        jsonDecode(results[1].stdout.toString()) as List<Object?>;
    final byNumber = <int, RelayIssueRaw>{};
    for (final item in [...openList, ...closedList]) {
      if (item is Map<String, Object?>) {
        final parsed = RelayIssueRaw.fromJson(item);
        byNumber[parsed.number] = parsed;
      }
    }
    final combined = byNumber.values.toList()
      ..sort((a, b) => b.number.compareTo(a.number));
    return (issues: combined, ok: 'true', error: '');
  } catch (_) {
    return (
      issues: const <RelayIssueRaw>[],
      ok: 'false',
      error: 'invalid JSON response from $cli',
    );
  }
}

Future<bool> _commandExists(String cmd) async {
  final res = await Process.run('which', [cmd]);
  return res.exitCode == 0;
}

Future<String?> _runCapture(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
}) async {
  try {
    final res = await Process.run(executable, args, environment: environment);
    if (res.exitCode != 0) return null;
    return res.stdout.toString().trim();
  } catch (_) {
    return null;
  }
}

String _firstNonEmpty(List<String?> candidates) {
  for (final c in candidates) {
    if (c != null && c.trim().isNotEmpty) return c.trim();
  }
  return '';
}
