import 'dart:io';

import 'package:args/args.dart';
import 'package:io/ansi.dart';
import 'package:kevmoo_scripts/src/repo_align/repo_align_runner.dart';

void main(List<String> args) {
  final parser = ArgParser()
    ..addCommand('check')
    ..addCommand('fix')
    ..addOption(
      'repo',
      abbr: 'r',
      help: 'Target a specific repository by name (e.g. stats, pubviz)',
    )
    ..addFlag(
      'json',
      help: 'Output check results in JSON format',
      negatable: false,
    )
    ..addFlag('lints', help: 'Fix/synchronize analysis_options.yaml')
    ..addFlag(
      'ci',
      help: 'Fix/synchronize CI workflows (lower_bound, complexity, autosubmit, dependabot)',
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
      ..writeln(red.wrap('Error: ${e.toString()}'))
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
  final jsonOutput = parsed['json'] as bool;
  final dryRun = parsed['dry-run'] as bool;
  final fixLints = parsed['lints'] as bool;
  final fixCi = parsed['ci'] as bool;
  final fixGitHub = parsed['github'] as bool;

  final runner = RepoAlignRunner();

  if (commandName == 'check') {
    runner.runCheck(targetRepo: targetRepo, jsonOutput: jsonOutput);
  } else if (commandName == 'fix') {
    runner.runFix(
      targetRepo: targetRepo,
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
