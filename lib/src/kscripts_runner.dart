import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dart_clean.dart';
import 'gerrit_view.dart';
import 'gh_clean.dart';
import 'gh_issues.dart';
import 'gh_view.dart';
import 'git_org_clean.dart';
import 'git_up.dart';
import 'lint_cleanup.dart';
import 'pr_check.dart';
import 'puppy.dart';
import 'repo_align/repo_align_runner.dart';
import 'shared/gh_args.dart';
import 'testable_print.dart';
import 'tighten.dart';

/// Top-level description for `kscripts --help` (must match `README.md`).
const kscriptsDescription =
    'Unified CLI runner for kevmoo_scripts developer utilities.';

/// Metadata and entrypoint delegate for a `kscripts` subcommand.
final class KScriptSubcommand {
  final String name;
  final String description;
  final FutureOr<void> Function(List<String> args) run;

  const new({required this.name, required this.description, required this.run});
}

/// Canonical subcommands exposed by `kscripts`.
const kscriptSubcommands = <KScriptSubcommand>[
  KScriptSubcommand(
    name: 'dart-clean',
    description: 'Find and kill orphaned Dart processes.',
    run: runDartCleanCli,
  ),
  KScriptSubcommand(
    name: 'gerrit-view',
    description: 'Complete overview of your active work on Gerrit.',
    run: runGerritViewCli,
  ),
  KScriptSubcommand(
    name: 'gh-clean',
    description:
        'Clean up local branches and worktrees for merged GitHub pull '
        'requests.',
    run: runGhCleanCli,
  ),
  KScriptSubcommand(
    name: 'gh-issues',
    description: 'Complete overview of your open assigned issues on GitHub.',
    run: runGhIssuesCli,
  ),
  KScriptSubcommand(
    name: 'gh-view',
    description: 'Complete overview of your active pull requests on GitHub.',
    run: runGhViewCli,
  ),
  KScriptSubcommand(
    name: 'git-org-clean',
    description: 'Analyze a GitHub organization for archive/delete candidates.',
    run: runGitOrgCleanCli,
  ),
  KScriptSubcommand(
    name: 'git-up',
    description: 'Safely switch to and update the default branch.',
    run: runGitUpCli,
  ),
  KScriptSubcommand(
    name: 'lint-cleanup',
    description: 'Clean up analysis_options.yaml files.',
    run: runLintCleanupCli,
  ),
  KScriptSubcommand(
    name: 'pr-check',
    description: 'Validate local CI parity before running gh pr create.',
    run: runPrCheckCli,
  ),
  KScriptSubcommand(
    name: 'puppy',
    description: 'Run a command in all package directories.',
    run: runPuppyCli,
  ),
  KScriptSubcommand(
    name: 'repo-align',
    description: 'Personal GitHub Repositories Alignment & Audit Tool',
    run: runRepoAlignCli,
  ),
  KScriptSubcommand(
    name: 'tighten',
    description: 'Tighten workspace dependencies.',
    run: runTightenCli,
  ),
];

/// Prescriptive hints for common subcommand mistakes (Zero-Alias CLI Design).
const commonKScriptMistakes = <String, String>{
  'clean': 'gh-clean',
  'pr-clean': 'gh-clean',
  'pr-cleanup': 'gh-clean',
  'view': 'gh-view',
  'prs': 'gh-view',
  'pr-view': 'gh-view',
  'issues': 'gh-issues',
  'gerrit': 'gerrit-view',
  'align': 'repo-align',
  'lint': 'lint-cleanup',
  'lints': 'lint-cleanup',
  'org-clean': 'git-org-clean',
  'up': 'git-up',
  'triage': 'gh-triage',
  'pr-triage': 'gh-triage',
  'orient': 'gh-orient',
  'post': 'gh-orient',
  'preflight': 'pr-check',
  'gh-preflight': 'pr-check',
  'check': 'pr-check',
};

/// Prints `kscripts` usage and available subcommands.
void printKScriptsUsage() {
  print(kscriptsDescription);
  print('');
  print('Usage: kscripts <subcommand> [arguments]');
  print('');
  print('Available subcommands:');
  final width = kscriptSubcommands
      .map((c) => c.name.length)
      .fold(0, (a, b) => a > b ? a : b);
  for (final cmd in kscriptSubcommands) {
    print('  ${cmd.name.padRight(width + 2)}${cmd.description}');
  }
  print('');
  print('Run "kscripts help <subcommand>" for more information on a command.');
}

/// Resolves a subcommand by exact name, returning `null` if not found.
KScriptSubcommand? findKScriptSubcommand(String name) {
  for (final cmd in kscriptSubcommands) {
    if (cmd.name == name) return cmd;
  }
  return null;
}

/// Suggests a canonical subcommand name for [input] if one matches.
String? suggestKScriptSubcommand(String input) {
  final normalized = input.trim().toLowerCase();
  final fromMap = commonKScriptMistakes[normalized];
  if (fromMap != null) return fromMap;

  final hyphenated = normalized.replaceAll('_', '-');
  if (findKScriptSubcommand(hyphenated) != null) {
    return hyphenated;
  }
  return null;
}

/// Resolves effective CLI arguments when `kscripts` is invoked via a multicall
/// shim (`KSCRIPTS_AS=<subcommand>`) or symlink (`argv[0]` matching a
/// subcommand name).
List<String> resolveEffectiveKScriptsArgs(
  List<String> args, {
  String? invokedAsEnv,
  String? executablePath,
}) {
  final candidate =
      invokedAsEnv ??
      Platform.environment['KSCRIPTS_AS'] ??
      p.basenameWithoutExtension(executablePath ?? Platform.executable);
  if (candidate != 'kscripts' && findKScriptSubcommand(candidate) != null) {
    return [candidate, ...args];
  }
  return args;
}

/// Checks whether the compiled `kscripts` binary is older than the local
/// `scripts.dart` checkout's `main` ref (using `KSCRIPTS_REPO_DIR` or the
/// `dart install` bundle's `../../pubspec.lock` path).
void checkKScriptsStaleness({
  String? repoDirEnv,
  File? executableFile,
  void Function(String)? onStderr,
}) {
  final emit = onStderr ?? (String line) => stderr.writeln(line);
  final exe = executableFile ?? File(Platform.resolvedExecutable);
  final exeName = p.basenameWithoutExtension(exe.path);
  // Skip when running under `dart test` or `dart run` VM executable.
  if (exeName == 'dart' || exeName == 'dartaotruntime') return;

  final explicitDir = repoDirEnv ?? Platform.environment['KSCRIPTS_REPO_DIR'];
  final repoPath = (explicitDir != null && explicitDir.trim().isNotEmpty)
      ? explicitDir.trim()
      : _resolveRepoDirFromBundleLock(exe);

  // No local checkout to compare against (e.g. a `git` or `hosted` install
  // without `KSCRIPTS_REPO_DIR`); stay silent rather than nagging every run.
  if (repoPath == null) return;

  final mainRef = File(p.join(repoPath, '.git', 'refs', 'heads', 'main'));
  if (!mainRef.existsSync() || !exe.existsSync()) return;

  try {
    final binModified = File(exe.resolveSymbolicLinksSync())
        .statSync()
        .modified;
    final mainModified = mainRef.statSync().modified;
    if (mainModified.isAfter(binModified)) {
      emit(
        '⚠️ Note: kscripts binary is older than $repoPath (main). '
        'Run "upkeep update dart_install" to refresh.',
      );
    }
  } catch (_) {}
}

String? _resolveRepoDirFromBundleLock(File exe) {
  try {
    final resolvedExe = File(exe.resolveSymbolicLinksSync());
    // Layout: <app-bundles>/kevmoo_scripts/<source>/<version>/bundle/bin/kscripts
    final lockFile = File(
      p.normalize(p.join(resolvedExe.parent.path, '..', '..', 'pubspec.lock')),
    );
    if (!lockFile.existsSync()) return null;
    final yaml = loadYaml(lockFile.readAsStringSync());
    if (yaml is! YamlMap) return null;
    final packages = yaml['packages'] as YamlMap?;
    final entry = packages?['kevmoo_scripts'] as YamlMap?;
    // Only a `path` install points at a live local checkout. A `git` install
    // records a repo-internal subdirectory (e.g. `path: "."`), which would
    // otherwise resolve against the current working directory.
    if (entry?['source']?.toString() != 'path') return null;
    final desc = entry?['description'] as YamlMap?;
    final rawPath = desc?['path']?.toString();
    if (rawPath == null || rawPath.isEmpty) return null;
    // `relative: true` paths are relative to the lock file, never to the CWD.
    final base = desc?['relative'] == true ? lockFile.parent.path : '';
    final repoDir = p.normalize(p.join(base, rawPath));
    return p.isAbsolute(repoDir) ? repoDir : null;
  } catch (_) {
    return null;
  }
}

/// Entrypoint dispatcher for `kscripts`.
Future<void> runKScriptsCli(List<String> rawArgs) async {
  checkKScriptsStaleness();
  final args = resolveEffectiveKScriptsArgs(rawArgs);

  if (args.isEmpty ||
      args.first == '--help' ||
      args.first == '-h' ||
      (args.first == 'help' && args.length == 1)) {
    printKScriptsUsage();
    return;
  }

  if (args.first == 'help' && args.length > 1) {
    final targetName = args[1];
    final subcommand = findKScriptSubcommand(targetName);
    if (subcommand == null) {
      _reportUnknownSubcommand(targetName);
      return;
    }
    await subcommand.run(const ['--help']);
    return;
  }

  final commandName = args.first;
  final subcommand = findKScriptSubcommand(commandName);
  if (subcommand == null) {
    _reportUnknownSubcommand(commandName);
    return;
  }

  await subcommand.run(args.sublist(1));
}

void _reportUnknownSubcommand(String commandName) {
  final suggestion = suggestKScriptSubcommand(commandName);
  final hint = suggestion != null
      ? ' Did you mean "kscripts $suggestion"?'
      : '';
  setError(
    message:
        'Unknown subcommand "$commandName".$hint\n\n'
        'Run "kscripts --help" to see available subcommands.',
    exitCode: ExitCode.usage.code,
  );
}

Future<void> runDartCleanCli(List<String> args) async {
  await runCliGuarded(() async {
    final options = parseDartCleanOptions(args);

    if (options.help) {
      print('Find and kill orphaned Dart processes.');
      print('');
      print(dartCleanOptionsUsage);
      return;
    }

    await runDartClean(options);
  }, usageForFormatException: dartCleanOptionsUsage);
}

Future<void> runGerritViewCli(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'path-to-gerrit-repo',
      abbr: 'p',
      help: 'Path to a local gerrit repo. Defaults to CWD.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gerrit-view',
    description: 'Complete overview of your active work on Gerrit.',
  );
  if (results == null) return;

  final gerritRepo = results['path-to-gerrit-repo'] as String?;
  await runCliGuarded(() => runGerritView(gerritRepo: gerritRepo));
}

Future<void> runGhCleanCli(List<String> arguments) async {
  final parser = GhCleanOptions.createArgParser();
  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gh-clean',
    description:
        'Clean up local branches and worktrees for merged GitHub pull '
        'requests.',
  );
  if (results == null) return;

  final limitRaw = results['limit'] as String;
  final parsedLimit = int.tryParse(limitRaw);
  if (parsedLimit == null || parsedLimit <= 0) {
    setError(
      message:
          'Invalid value for --limit: "$limitRaw". '
          'Must be a positive integer.\n\n${parser.usage}',
      exitCode: ExitCode.usage.code,
    );
    return;
  }
  var limit = parsedLimit;
  if (limit > 100) {
    stderr.writeln(
      'Warning: --limit exceeds GitHub API ceiling of 100. Clamping to 100.',
    );
    limit = 100;
  }

  final lastNDaysResult = parseLastNDaysOption(results, parser);
  if (!lastNDaysResult.valid) return;

  final options = GhCleanOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: limit,
    lastNDays: lastNDaysResult.value,
    apply: results['apply'] as bool,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
    localRoot: results['local-root'] as String?,
    skipSync: results['skip-sync'] as bool,
    skipWorktrees: results['skip-worktrees'] as bool,
    skipRemoteBranches: results['skip-remote-branches'] as bool,
    includeOwned: results['include-owned'] as bool,
  );

  await runCliGuarded(
    () => runGhClean(options: options, onProgress: stderr.writeln),
  );
}

Future<void> runGhIssuesCli(List<String> arguments) async {
  final parser = GhIssuesOptions.createArgParser();
  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gh-issues',
    description: 'Complete overview of your open assigned issues on GitHub.',
  );
  if (results == null) return;

  final lastNDaysResult = parseLastNDaysOption(results, parser);
  if (!lastNDaysResult.valid) return;

  int? createdDays;
  final createdDaysRaw = results['created-days'] as String?;
  if (createdDaysRaw != null) {
    final parsed = int.tryParse(createdDaysRaw);
    if (parsed == null || parsed < 0) {
      setError(
        message:
            'Invalid value for --created-days: "$createdDaysRaw". '
            'Must be a non-negative integer (0 for no limit).\n\n'
            '${parser.usage}',
        exitCode: ExitCode.usage.code,
      );
      return;
    }
    createdDays = parsed > 0 ? parsed : 0;
  }

  final options = GhIssuesOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: int.tryParse(results['limit'] as String) ?? 50,
    lastNDays: lastNDaysResult.value,
    createdDays: createdDays,
    checkLinkedPrs: results['linked-prs'] as bool,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
  );

  await runCliGuarded(() => runGhIssues(options: options));
}

Future<void> runGhViewCli(List<String> arguments) async {
  final parser = GhViewOptions.createArgParser();
  final results = parseCliArgs(
    parser,
    arguments,
    commandName: 'gh-view',
    description: 'Complete overview of your active pull requests on GitHub.',
  );
  if (results == null) return;

  final lastNDaysResult = parseLastNDaysOption(results, parser);
  if (!lastNDaysResult.valid) return;

  final options = GhViewOptions(
    user: results['user'] as String,
    repo: results['repo'] as String?,
    limit: int.tryParse(results['limit'] as String) ?? 50,
    lastNDays: lastNDaysResult.value,
    json: results['json'] as bool,
    markdown: results['markdown'] as bool,
    checkLocal: results['local'] as bool,
    localRoot: results['local-root'] as String?,
    enricher: results['enricher'] as String?,
  );

  await runCliGuarded(() => runGhView(options: options));
}

Future<void> runGitOrgCleanCli(List<String> args) async {
  await runCliGuarded(() async {
    final cleanArgs = parseCleanArgs(args);
    if (cleanArgs.help) {
      print('Analyze a GitHub organization for archive/delete candidates.');
      print('');
      print('Usage: git-org-clean [arguments]');
      print('');
      print('Options:');
      print(cleanArgsUsage);
      return;
    }
    await runGitOrgClean(cleanArgs);
  });
}

Future<void> runGitUpCli(List<String> arguments) async {
  final help = arguments.contains('--help') || arguments.contains('-h');
  if (help) {
    print('Safely switch to and update the default branch.');
    print('Usage: git-up [--check | -c] [--verbose | -v] [--help | -h]');
    return;
  }

  final verbose = arguments.contains('--verbose') || arguments.contains('-v');
  final check = arguments.contains('--check') || arguments.contains('-c');

  try {
    await gitUp(check: check);
  } on GitUpException catch (e, stack) {
    setError(
      message: e.message,
      exitCode: e.exitCode,
      stack: verbose ? stack : null,
    );
  } on ProcessException catch (e, stack) {
    setError(
      message: 'Git error: ${e.message}',
      exitCode: 1,
      stack: verbose ? stack : null,
    );
  } catch (e, stack) {
    setError(
      message: 'Unexpected error: $e',
      exitCode: ExitCode.software.code,
      stack: verbose ? stack : null,
    );
  }
}

Future<void> runLintCleanupCli(List<String> arguments) async {
  final LintCleanupOptions options;

  try {
    options = parseLintCleanupOptions(arguments);
  } on UsageException catch (e) {
    setError(
      message: '${e.message}\n\n${e.usage}',
      exitCode: ExitCode.usage.code,
    );
    return;
  }

  if (options.help) {
    print('Clean up analysis_options.yaml files.');
    print('');
    print('Usage: lint_cleanup [arguments]');
    print('');
    print('Options:');
    print(lintCleanupUsage);
    return;
  }

  final pkgDir = options.packageDir;
  final rewrite = options.rewrite;

  Directory pkgDirectory;
  if (pkgDir == null) {
    pkgDirectory = Directory.current;
  } else {
    pkgDirectory = Directory(pkgDir);
    if (!pkgDirectory.existsSync()) {
      setError(
        message: 'Provided package-dir `$pkgDir` does not exist!',
        exitCode: ExitCode.usage.code,
      );
      return;
    }
  }

  return lintCleanup(packageDirectory: pkgDirectory, rewrite: rewrite);
}

Future<void> runPuppyCli(List<String> args) async {
  await runCliGuarded(() async {
    final puppyArgs = parseRunArgs(args);
    if (puppyArgs.help) {
      print('Run a command in all package directories.');
      print('');
      print('Usage: puppy [arguments] <command to invoke>');
      print('');
      print('Options:');
      print(runArgsUsage);
      return;
    }
    await runPuppy(puppyArgs);
  });
}

void runRepoAlignCli(List<String> args) {
  final parser = ArgParser()
    ..addCommand('check')
    ..addCommand('fix')
    ..addOption(
      'repo',
      abbr: 'r',
      help: 'Target a specific repository by name (e.g. stats, pubviz)',
    )
    ..addOption(
      'dir',
      abbr: 'd',
      help:
          'Target a specific checkout or sibling worktree directory for local '
          'checks/fixes',
    )
    ..addFlag(
      'json',
      help: 'Output check results in JSON format',
      negatable: false,
    )
    ..addFlag('lints', help: 'Fix/synchronize analysis_options.yaml')
    ..addFlag(
      'ci',
      help:
          'Fix/synchronize CI workflows '
          '(lower_bound, complexity, autosubmit, dependabot)',
    )
    ..addFlag(
      'github',
      help: 'Fix/synchronize GitHub remote settings (auto-merge, rulesets)',
    )
    ..addFlag(
      'dry-run',
      abbr: 'n',
      help: 'Preview changes without modifying files or remote settings',
    )
    ..addFlag('help', abbr: 'h', help: 'Show command usage', negatable: false);

  ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } catch (e) {
    stderr
      ..writeln(red.wrap('Error: $e'))
      ..writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (parsed['help'] == true || args.isEmpty) {
    print('Personal GitHub Repositories Alignment & Audit Tool');
    print('Usage: repo-align <check|fix> [options]\n');
    print(parser.usage);
    return;
  }

  final commandName = parsed.command?.name ?? 'check';
  final targetRepo = parsed['repo'] as String?;
  final targetDir = parsed['dir'] as String?;
  final jsonOutput = parsed['json'] as bool;
  final dryRun = parsed['dry-run'] as bool;
  final fixLints = parsed['lints'] as bool;
  final fixCi = parsed['ci'] as bool;
  final fixGitHub = parsed['github'] as bool;

  final runner = RepoAlignRunner();

  if (commandName == 'check') {
    runner.runCheck(
      targetRepo: targetRepo,
      targetDir: targetDir,
      jsonOutput: jsonOutput,
    );
  } else if (commandName == 'fix') {
    runner.runFix(
      targetRepo: targetRepo,
      targetDir: targetDir,
      fixLints: fixLints,
      fixCi: fixCi,
      fixGitHub: fixGitHub,
      dryRun: dryRun,
    );
  } else {
    stderr.writeln(red.wrap('Unknown command: $commandName'));
    exitCode = 64;
  }
}

Future<void> runTightenCli(List<String> args) async {
  final TightenOptions options;
  try {
    options = parseTightenOptions(args);
  } on UsageException catch (e) {
    setError(
      message: '${e.message}\n\n${e.usage}',
      exitCode: ExitCode.usage.code,
    );
    return;
  }

  if (options.help) {
    print('Tighten workspace dependencies.');
    print('');
    print(tightenUsage);
    return;
  }

  try {
    await tighten(isWorkspace: options.workspace);
  } on TightenException catch (e) {
    setError(message: e.message, exitCode: ExitCode.config.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
