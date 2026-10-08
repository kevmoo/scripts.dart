import 'dart:io';

import 'package:args/args.dart';

/// Top-level description for `kscripts relay-whoami --help`.
const relayWhoamiDescription =
    'Cross-machine agent relay identity, envelope, and sync status checker.';

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
        env['GEMINI_MODEL'] ??
        '',
  );
}
