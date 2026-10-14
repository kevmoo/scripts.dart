import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../shared/gh_args.dart';

/// Command-line options for `kscripts pr-cleanup`.
class PrCleanupOptions {
  final String user;
  final String? repo;
  final int limit;
  final int? lastNDays;
  final String? localRoot;
  final String? dartSdkPath;
  final bool skipGerrit;
  final bool apply;
  final bool markdown;
  final bool json;

  const new({
    this.user = '@me',
    this.repo,
    this.limit = 50,
    this.lastNDays = 14,
    this.localRoot,
    this.dartSdkPath,
    this.skipGerrit = false,
    this.apply = false,
    this.markdown = true,
    this.json = false,
  });

  static ArgParser createArgParser() => ArgParser()
    ..addOption(
      'user',
      abbr: 'u',
      defaultsTo: '@me',
      help: 'GitHub user to query for PRs.',
    )
    ..addMultiOption(
      'repo',
      abbr: 'R',
      help:
          'Filter to specific repository/repositories (e.g. '
          '-R dart-lang/tools).',
    )
    ..addOption(
      'limit',
      abbr: 'l',
      defaultsTo: '50',
      help: 'Maximum landed PRs to fetch from GitHub (max 100).',
    )
    ..addOption(
      'last-n-days',
      abbr: 'd',
      defaultsTo: '14',
      help:
          'Include PRs and activity from the last N days (default 14; '
          'pass empty/0 to query all).',
    )
    ..addOption(
      'local-root',
      help: 'Root directory for local Git repositories (default ~/github).',
    )
    ..addOption(
      'dart-sdk',
      abbr: 'p',
      help:
          'Path to local dart-sdk repository for Gerrit check '
          '(default ~/github/dart-sdk).',
    )
    ..addFlag(
      'skip-gerrit',
      negatable: false,
      help:
          'Skip Gerrit Dart SDK inspection even if ~/github/dart-sdk '
          'exists.',
    )
    ..addFlag(
      'apply',
      negatable: false,
      help:
          'Execute pruning of Bucket B (safe to prune) worktrees and '
          'branches across GitHub and Gerrit.',
    )
    ..addFlag(
      'markdown',
      defaultsTo: true,
      help: 'Output a concise Markdown summary.',
    )
    ..addFlag('json', negatable: false, help: 'Output machine-readable JSON.')
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  static PrCleanupOptions parse(ArgResults results) {
    final limitRaw = results['limit'] as String;
    final parsedLimit = int.tryParse(limitRaw);
    if (parsedLimit == null || parsedLimit < 1 || parsedLimit > 100) {
      throw UsageException(
        'Invalid limit "$limitRaw": must be between 1 and 100.',
        createArgParser().usage,
      );
    }

    final daysRaw = results['last-n-days'] as String?;
    int? lastNDays = 14;
    if (daysRaw != null && daysRaw.isNotEmpty) {
      final parsedDays = int.tryParse(daysRaw);
      if (parsedDays == null || parsedDays < 0) {
        throw UsageException(
          'Invalid last-n-days "$daysRaw": must be a non-negative integer.',
          createArgParser().usage,
        );
      }
      lastNDays = (parsedDays == 0) ? null : parsedDays;
    }

    return PrCleanupOptions(
      user: results['user'] as String? ?? '@me',
      repo: parseRepoOption(results),
      limit: parsedLimit,
      lastNDays: lastNDays,
      localRoot: results['local-root'] as String?,
      dartSdkPath: results['dart-sdk'] as String?,
      skipGerrit: results['skip-gerrit'] as bool? ?? false,
      apply: results['apply'] as bool? ?? false,
      markdown: results['markdown'] as bool? ?? true,
      json: results['json'] as bool? ?? false,
    );
  }
}
