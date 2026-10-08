import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';

import 'pr_triage/github_cli.dart';
import 'pr_triage/triage_report.dart';
import 'testable_print.dart';

export 'pr_triage/github_cli.dart';
export 'pr_triage/triage_report.dart'
    show TriageData, buildTriageReport, truncateLog;

/// Description for `kscripts pr-triage --help` (must match `README.md`).
const prTriageDescription =
    'Triage open PR comments, reviews, and CI check failures.';

class _PrTriageFailure implements Exception {
  final String message;
  new(this.message);
}

Never _failTriage(String message) => throw _PrTriageFailure(message);

ArgParser _buildReRequestArgParser() => buildPrContextArgParser()
  ..addOption(
    'dismiss',
    help:
        'Numeric database ID of a stale CHANGES_REQUESTED review to dismiss '
        'before re-requesting review.',
  )
  ..addOption(
    'message',
    abbr: 'm',
    help: 'Audit message when dismissing a review via --dismiss.',
  )
  ..addOption(
    'comment',
    abbr: 'c',
    help: 'Optional top-level PR comment to post before re-requesting review.',
  );

void _printPrTriageUsage(ArgParser parser) {
  print(prTriageDescription);
  print('');
  print('Usage:');
  print('  kscripts pr-triage [options]');
  print(
    '  kscripts pr-triage resolve <thread_id> [<comment_id> "<body_text>"]',
  );
  print(
    '  kscripts pr-triage re-request <reviewer_login> '
    '[--comment "<reply_body>"] '
    '[--dismiss <review_database_id> -m "<message>"]',
  );
  print('');
  print('Options:');
  print(parser.usage);
}

const _commonPrTriageSubcommandMistakes = <String, String>{
  'dismiss': 're-request <reviewer_login> --dismiss <review_database_id>',
  'rerequest': 're-request <reviewer_login>',
  're_request': 're-request <reviewer_login>',
  'reply': 'resolve <thread_id> <comment_id> "<body_text>"',
};

Future<void> runPrTriageCli(List<String> args) async {
  final parser = buildPrContextArgParser()
    ..addCommand('resolve', buildPrContextArgParser())
    ..addCommand('re-request', _buildReRequestArgParser());
  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    setError(
      message: 'Error: ${e.message}\n\n${parser.usage}',
      exitCode: ExitCode.usage.code,
    );
    return;
  }

  if (results.flag('help') || results.command?.flag('help') == true) {
    _printPrTriageUsage(parser);
    return;
  }

  try {
    await _runTriage(results);
  } on _PrTriageFailure catch (e) {
    setError(message: 'Error: ${e.message}', exitCode: ExitCode.usage.code);
  } catch (e, stack) {
    setError(
      message: 'Error during triage: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}

Future<void> _runTriage(ArgResults results) async {
  final subCmd = results.command;
  if (subCmd != null && subCmd.name == 'resolve') {
    await _handleResolveCommand(results, subCmd);
    return;
  }
  if (subCmd != null && subCmd.name == 're-request') {
    await _handleReRequestCommand(results, subCmd);
    return;
  }

  if (results.rest.isNotEmpty) {
    final firstArg = results.rest.first.trim().toLowerCase();
    final suggestion = _commonPrTriageSubcommandMistakes[firstArg];
    if (suggestion != null) {
      _failTriage(
        'Unknown pr-triage subcommand "${results.rest.first}". '
        'Did you mean "kscripts pr-triage $suggestion"?',
      );
    }
  }

  final targetDir = results.option('dir');
  final prInput =
      results.option('pr') ??
      (results.rest.isNotEmpty ? results.rest.first : null);

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
  );

  final (data, conflictAnalysis) = await fetchTriageData(context);
  final report = buildTriageReport(data, conflictAnalysis: conflictAnalysis);

  print('\n================== REPORT ==================\n');
  stdout.write(report);
}

({String threadId, String? commentId, String? bodyText}) _parseResolveArgs(
  List<String> positional,
) {
  final (threadId, commentId, bodyText) = switch (positional) {
    [final t] => (t, null, null),
    [final t, final c, final b] => (t, c, b),
    _ => _failTriage(
      'Invalid arguments for resolve subcommand.\n'
      'Usage:\n'
      '  kscripts pr-triage resolve <thread_id>\n'
      '  kscripts pr-triage resolve <thread_id> <comment_id> "<body_text>"',
    ),
  };

  if (commentId != null && !RegExp(r'^\d+$').hasMatch(commentId)) {
    _failTriage('<comment_id> must be a numeric database ID.');
  }
  if (bodyText != null && bodyText.trim().isEmpty) {
    _failTriage('<body_text> cannot be empty.');
  }

  return (threadId: threadId, commentId: commentId, bodyText: bodyText);
}

Future<void> _handleResolveCommand(
  ArgResults results,
  ArgResults resolveCmd,
) async {
  final parsed = _parseResolveArgs(resolveCmd.rest);
  final targetDir = resolveCmd.option('dir') ?? results.option('dir');
  final prInput = resolveCmd.option('pr') ?? results.option('pr');

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
    requireLocalRepo: false,
  );

  if (parsed.commentId != null && parsed.bodyText != null) {
    print(
      'Replying to comment ${parsed.commentId} and resolving thread '
      '${parsed.threadId}...',
    );
  } else {
    print('Resolving thread ${parsed.threadId}...');
  }

  await replyAndResolveThread(
    context,
    threadId: parsed.threadId,
    commentId: parsed.commentId,
    body: parsed.bodyText,
  );
  print('Successfully resolved thread ${parsed.threadId}.');
}

({
  String reviewerLogins,
  String? dismissReviewId,
  String? dismissMessage,
  String? comment,
})
_parseReRequestArgs(ArgResults reRequestCmd) {
  if (reRequestCmd.rest.length != 1) {
    _failTriage(
      'Invalid arguments for re-request subcommand.\n'
      'Usage:\n'
      '  kscripts pr-triage re-request <reviewer_login> '
      '[--comment "<reply_body>"] '
      '[--dismiss <review_database_id> -m "<message>"]',
    );
  }
  final normalizedLogins = normalizeReviewerLogins(reRequestCmd.rest.single);
  if (normalizedLogins.isEmpty) {
    _failTriage('<reviewer_login> cannot be empty.');
  }

  final dismissId = reRequestCmd.option('dismiss')?.trim();
  final dismissMessage = reRequestCmd.option('message');
  final comment = reRequestCmd.option('comment');

  if (dismissId != null &&
      dismissId.isNotEmpty &&
      !RegExp(r'^\d+$').hasMatch(dismissId)) {
    _failTriage('<review_database_id> must be a numeric database ID.');
  }
  if (dismissMessage != null && (dismissId == null || dismissId.isEmpty)) {
    _failTriage('--message requires --dismiss <review_database_id>.');
  }
  if (comment != null && comment.trim().isEmpty) {
    _failTriage('--comment body cannot be empty.');
  }

  return (
    reviewerLogins: normalizedLogins,
    dismissReviewId: (dismissId != null && dismissId.isNotEmpty)
        ? dismissId
        : null,
    dismissMessage: dismissMessage,
    comment: comment,
  );
}

Future<void> _handleReRequestCommand(
  ArgResults results,
  ArgResults reRequestCmd,
) async {
  final parsed = _parseReRequestArgs(reRequestCmd);
  final targetDir = reRequestCmd.option('dir') ?? results.option('dir');
  final prInput = reRequestCmd.option('pr') ?? results.option('pr');

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
    requireLocalRepo: false,
  );

  final mentions = formatReviewerMentions(parsed.reviewerLogins);
  if (parsed.comment != null) {
    print('Posting top-level comment on PR #${context.prNumber}...');
  }
  if (parsed.dismissReviewId != null) {
    print('Dismissing stale review ${parsed.dismissReviewId}...');
  }
  print('Re-requesting review from $mentions on PR #${context.prNumber}...');

  await reRequestPrReview(
    context,
    reviewerLogins: parsed.reviewerLogins,
    comment: parsed.comment,
    dismissReviewId: parsed.dismissReviewId,
    dismissMessage: parsed.dismissMessage,
  );
  print('Successfully re-requested review from $mentions.');
}
