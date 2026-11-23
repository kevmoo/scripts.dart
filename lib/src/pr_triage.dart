import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';

import 'pr_triage/fetch_pr_sync_status.dart';
import 'pr_triage/github_cli.dart';
import 'pr_triage/triage_report.dart';
import 'testable_print.dart';

export 'pr_triage/github_cli.dart';

/// Description for `kscripts pr-triage --help` (must match `README.md`).
const prTriageDescription =
    'Triage open PR comments, reviews, and CI check failures.';

class _PrTriageFailure implements Exception {
  final String message;
  new(this.message);
}

Never _failTriage(String message) => throw _PrTriageFailure(message);

const _negOneArgSentinel = '__pr_triage_minus_one__';

String _restoreNegOne(String value) =>
    value == _negOneArgSentinel ? '-1' : value;

String? _restoreOptionalNegOne(String? value) =>
    value == null ? null : _restoreNegOne(value);

String _validateReactionFlag(String raw, {required String label}) {
  final clean = raw.trim();
  if (clean != '+1' && clean != '-1') {
    _failTriage('$label must be "+1" or "-1" (got "$raw").');
  }
  return clean;
}

ArgParser _buildReplyArgParser() => buildPrContextArgParser()
  ..addOption(
    'react',
    help:
        'Optional "+1" or "-1" reaction to post on <comment_id> alongside '
        'the reply.',
  );

ArgParser _buildResolveArgParser() => buildPrContextArgParser()
  ..addOption(
    'react',
    help:
        'Optional "+1" or "-1" reaction to post on <comment_id> before '
        'resolving.',
  );

ArgParser _buildReactArgParser() => buildPrContextArgParser()
  ..addFlag(
    'issue-comment',
    negatable: false,
    help:
        'React to a general PR/issue conversation comment instead of an '
        'inline review comment.',
  );

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
    '  kscripts pr-triage reply [--react <+1|-1>] <comment_id> '
    '"<reply_body>"',
  );
  print(
    '  kscripts pr-triage resolve [--react <+1|-1>] <thread_id> '
    '[<comment_id> ["<body_text>"]]',
  );
  print('  kscripts pr-triage react [--issue-comment] <comment_id> <+1|-1>');
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
  'reaction': 'react <comment_id> <+1|-1> [--issue-comment]',
  'reactions': 'react <comment_id> <+1|-1> [--issue-comment]',
};

Future<void> runPrTriageCli(
  List<String> args, {
  CommandRunner runCommand = runCommand,
}) async {
  final parser = buildPrContextArgParser()
    ..addCommand('reply', _buildReplyArgParser())
    ..addCommand('resolve', _buildResolveArgParser())
    ..addCommand('react', _buildReactArgParser())
    ..addCommand('re-request', _buildReRequestArgParser());
  final sanitizedArgs = [
    for (final arg in args) arg == '-1' ? _negOneArgSentinel : arg,
  ];
  final ArgResults results;
  try {
    results = parser.parse(sanitizedArgs);
  } on FormatException catch (e) {
    final cleanMsg = e.message.replaceAll(_negOneArgSentinel, '-1');
    setError(
      message: 'Error: $cleanMsg\n\n${parser.usage}',
      exitCode: ExitCode.usage.code,
    );
    return;
  }

  if (results.flag('help') || results.command?.flag('help') == true) {
    _printPrTriageUsage(parser);
    return;
  }

  try {
    await _runTriage(results, runCommand: runCommand);
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

Future<void> _runTriage(
  ArgResults results, {
  required CommandRunner runCommand,
}) async {
  final subCmd = results.command;
  if (subCmd != null) {
    switch (subCmd.name) {
      case 'reply':
        await _handleReplyCommand(results, subCmd, runCommand: runCommand);
        return;
      case 'resolve':
        await _handleResolveCommand(results, subCmd, runCommand: runCommand);
        return;
      case 'react':
        await _handleReactCommand(results, subCmd, runCommand: runCommand);
        return;
      case 're-request':
        await _handleReRequestCommand(results, subCmd, runCommand: runCommand);
        return;
    }
  }

  final rest = results.rest.map(_restoreNegOne).toList();
  if (rest.isNotEmpty) {
    final firstArg = rest.first.trim().toLowerCase();
    final suggestion = _commonPrTriageSubcommandMistakes[firstArg];
    if (suggestion != null) {
      _failTriage(
        'Unknown pr-triage subcommand "${rest.first}". '
        'Did you mean "kscripts pr-triage $suggestion"?',
      );
    }
  }

  final targetDir = _restoreOptionalNegOne(results.option('dir'));
  final prInput =
      _restoreOptionalNegOne(results.option('pr')) ??
      (rest.isNotEmpty ? rest.first : null);

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
    runCommand: runCommand,
  );

  final (data, conflictAnalysis, resolvedFollowUps) = await _fetchTriageData(
    context,
  );
  final report = buildTriageReport(
    data,
    conflictAnalysis: conflictAnalysis,
    resolvedThreadsWithReviewerReplies: resolvedFollowUps,
  );

  print('\n================== REPORT ==================\n');
  stdout.write(report);
}

const _replyUsage =
    'Usage:\n'
    '  kscripts pr-triage reply [--react <+1|-1>] <comment_id> "<reply_body>"';

({String commentId, String bodyText, String? reaction}) _parseReplyArgs(
  List<String> positional, {
  String? rawReaction,
}) {
  final reaction = rawReaction != null
      ? _validateReactionFlag(rawReaction, label: '--react')
      : null;
  final (commentId, bodyText) = switch (positional) {
    [final c, final b] => (c, b),
    [final t, final _, final _] => _failTriage(
      '"reply" takes 2 positional arguments (<comment_id> "<reply_body>"), '
      'not 3. Omit thread ID "$t" to leave the thread unresolved, or use '
      '"resolve" to also resolve it.\n'
      '$_replyUsage',
    ),
    _ => _failTriage(
      'Invalid arguments for reply subcommand.\n'
      '$_replyUsage',
    ),
  };

  if (commentId.startsWith('PRRT_')) {
    _failTriage(
      '<comment_id> must be a numeric comment database ID, not a PRRT_ '
      'review thread ID ("$commentId"). Pass the numeric Comment ID from '
      'pr-triage output.\n'
      '$_replyUsage',
    );
  }
  if (!RegExp(r'^\d+$').hasMatch(commentId)) {
    _failTriage('<comment_id> must be a numeric database ID.');
  }
  if (bodyText.trim().isEmpty) {
    _failTriage('<reply_body> cannot be empty.');
  }

  return (commentId: commentId, bodyText: bodyText, reaction: reaction);
}

Future<void> _handleReplyCommand(
  ArgResults results,
  ArgResults replyCmd, {
  required CommandRunner runCommand,
}) async {
  final parsed = _parseReplyArgs(
    replyCmd.rest.map(_restoreNegOne).toList(),
    rawReaction: _restoreOptionalNegOne(replyCmd.option('react')),
  );
  final targetDir = _restoreOptionalNegOne(
    replyCmd.option('dir') ?? results.option('dir'),
  );
  final prInput = _restoreOptionalNegOne(
    replyCmd.option('pr') ?? results.option('pr'),
  );

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
    requireLocalRepo: false,
    runCommand: runCommand,
  );

  final reaction = parsed.reaction;
  print(
    reaction != null
        ? 'Replying to comment ${parsed.commentId} and reacting ($reaction) '
              '(leaving thread unresolved)...'
        : 'Replying to comment ${parsed.commentId} '
              '(leaving thread unresolved)...',
  );
  await replyToPrComment(
    context,
    commentId: parsed.commentId,
    body: parsed.bodyText,
    reaction: reaction,
    runCommand: runCommand,
  );
  print(
    'Successfully replied to comment ${parsed.commentId} '
    '(thread left unresolved).',
  );
}

({String threadId, String? commentId, String? bodyText, String? reaction})
_parseResolveArgs(List<String> positional, {String? rawReaction}) {
  final reaction = rawReaction != null
      ? _validateReactionFlag(rawReaction, label: '--react')
      : null;
  final (threadId, commentId, bodyText) = switch (positional) {
    [final t] when reaction == null => (t, null, null),
    [final t, final c] when reaction != null => (t, c, null),
    [final t, final c, final b] => (t, c, b),
    [final _] => _failTriage(
      '--react requires <comment_id> (numeric database ID).\n'
      'Usage:\n'
      '  kscripts pr-triage resolve --react <+1|-1> <thread_id> '
      '<comment_id> ["<body_text>"]',
    ),
    _ => _failTriage(
      'Invalid arguments for resolve subcommand.\n'
      'Usage:\n'
      '  kscripts pr-triage resolve <thread_id>\n'
      '  kscripts pr-triage resolve [--react <+1|-1>] <thread_id> '
      '<comment_id> ["<body_text>"]',
    ),
  };

  if (commentId != null && !RegExp(r'^\d+$').hasMatch(commentId)) {
    _failTriage('<comment_id> must be a numeric database ID.');
  }
  if (bodyText != null && bodyText.trim().isEmpty) {
    _failTriage('<body_text> cannot be empty.');
  }

  return (
    threadId: threadId,
    commentId: commentId,
    bodyText: bodyText,
    reaction: reaction,
  );
}

Future<void> _handleResolveCommand(
  ArgResults results,
  ArgResults resolveCmd, {
  required CommandRunner runCommand,
}) async {
  final parsed = _parseResolveArgs(
    resolveCmd.rest.map(_restoreNegOne).toList(),
    rawReaction: _restoreOptionalNegOne(resolveCmd.option('react')),
  );
  final targetDir = _restoreOptionalNegOne(
    resolveCmd.option('dir') ?? results.option('dir'),
  );
  final prInput = _restoreOptionalNegOne(
    resolveCmd.option('pr') ?? results.option('pr'),
  );

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
    requireLocalRepo: false,
    runCommand: runCommand,
  );

  print(_formatResolveStatusLine(parsed));
  await replyAndResolveThread(
    context,
    threadId: parsed.threadId,
    commentId: parsed.commentId,
    body: parsed.bodyText,
    reaction: parsed.reaction,
    runCommand: runCommand,
  );
  print('Successfully resolved thread ${parsed.threadId}.');
}

String _formatResolveStatusLine(
  ({String threadId, String? commentId, String? bodyText, String? reaction})
  parsed,
) {
  final hasReply = parsed.commentId != null && parsed.bodyText != null;
  final reaction = parsed.reaction;
  if (hasReply && reaction != null) {
    return 'Replying to comment ${parsed.commentId}, reacting ($reaction), '
        'and resolving thread ${parsed.threadId}...';
  }
  if (hasReply) {
    return 'Replying to comment ${parsed.commentId} and resolving thread '
        '${parsed.threadId}...';
  }
  if (reaction != null) {
    return 'Reacting ($reaction) to comment ${parsed.commentId} and resolving '
        'thread ${parsed.threadId}...';
  }
  return 'Resolving thread ${parsed.threadId}...';
}

({String commentId, String reaction, bool isIssueComment}) _parseReactArgs(
  ArgResults reactCmd,
) {
  final positional = reactCmd.rest.map(_restoreNegOne).toList();
  final (commentId, rawReaction) = switch (positional) {
    [final c, final r] => (c, r),
    _ => _failTriage(
      'Invalid arguments for react subcommand.\n'
      'Usage:\n'
      '  kscripts pr-triage react [--issue-comment] <comment_id> <+1|-1>',
    ),
  };

  if (!RegExp(r'^\d+$').hasMatch(commentId)) {
    _failTriage('<comment_id> must be a numeric database ID.');
  }
  final reaction = _validateReactionFlag(rawReaction, label: '<reaction>');
  return (
    commentId: commentId,
    reaction: reaction,
    isIssueComment: reactCmd.flag('issue-comment'),
  );
}

Future<void> _handleReactCommand(
  ArgResults results,
  ArgResults reactCmd, {
  required CommandRunner runCommand,
}) async {
  final parsed = _parseReactArgs(reactCmd);
  final targetDir = _restoreOptionalNegOne(
    reactCmd.option('dir') ?? results.option('dir'),
  );
  final prInput = _restoreOptionalNegOne(
    reactCmd.option('pr') ?? results.option('pr'),
  );

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
    requireLocalRepo: false,
    runCommand: runCommand,
  );

  final kindLabel = parsed.isIssueComment ? 'issue comment' : 'review comment';
  print(
    'Posting ${parsed.reaction} reaction on $kindLabel ${parsed.commentId}...',
  );
  await reactToPrComment(
    context,
    commentId: parsed.commentId,
    reaction: parsed.reaction,
    isIssueComment: parsed.isIssueComment,
    runCommand: runCommand,
  );
  print(
    'Successfully posted ${parsed.reaction} reaction on $kindLabel '
    '${parsed.commentId}.',
  );
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
  final normalizedLogins = normalizeReviewerLogins(
    _restoreNegOne(reRequestCmd.rest.single),
  );
  if (normalizedLogins.isEmpty) {
    _failTriage('<reviewer_login> cannot be empty.');
  }

  final dismissId = _restoreOptionalNegOne(reRequestCmd.option('dismiss'))
      ?.trim();
  final dismissMessage = _restoreOptionalNegOne(reRequestCmd.option('message'));
  final comment = _restoreOptionalNegOne(reRequestCmd.option('comment'));

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
  ArgResults reRequestCmd, {
  required CommandRunner runCommand,
}) async {
  final parsed = _parseReRequestArgs(reRequestCmd);
  final targetDir = _restoreOptionalNegOne(
    reRequestCmd.option('dir') ?? results.option('dir'),
  );
  final prInput = _restoreOptionalNegOne(
    reRequestCmd.option('pr') ?? results.option('pr'),
  );

  final context = await resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: _failTriage,
    requireLocalRepo: false,
    runCommand: runCommand,
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
    runCommand: runCommand,
  );
  print('Successfully re-requested review from $mentions.');
}

const _prViewFields =
    'number,title,state,author,reviewDecision,reviewRequests,mergeable,'
    'mergeStateStatus,baseRefName,headRefName,headRefOid,url';

Future<(TriageData, PrConflictAnalysis, List<PrReviewThread>)> _fetchTriageData(
  PrContext context,
) async {
  print(
    'Fetching details for PR #${context.prNumber} from '
    '${context.repoSlug}...',
  );
  print('Target directory: ${context.workingDir}');
  final viewOutput = await runCommand(context.ghExecutable(), [
    '-R',
    context.repoSlug,
    'pr',
    'view',
    context.prNumber,
    '--json',
    _prViewFields,
  ], workingDirectory: context.workingDir);
  final prData = jsonDecode(viewOutput) as Map<String, dynamic>;

  final syncStatus = await fetchPrSyncStatus(
    context,
    remoteBranch: prData['headRefName']?.toString(),
    remoteHeadSha: prData['headRefOid']?.toString(),
  );

  if (syncStatus.warning != null) {
    print('\nWARNING: ${syncStatus.warning}\n');
  }

  final conflictAnalysis = await analyzePrConflicts(context, prData);
  if (conflictAnalysis.isConflicting) {
    print(
      '\nWARNING: PR #${context.prNumber} has MERGE CONFLICTS with '
      'origin/${conflictAnalysis.baseRefName}!\n',
    );
  }

  print('Fetching review comments and threads...');
  final graphData = await fetchPrGraphQLData(context);
  final unresolvedThreads = graphData.reviewThreads
      .where((t) => !t.isResolved)
      .toList();
  final reviewComments = graphData.reviews
      .where((r) => r.body.trim().isNotEmpty)
      .toList();
  final generalComments = graphData.comments
      .where((c) => c.body.trim().isNotEmpty)
      .toList();

  final reviewers = summarizeReviewers(graphData, prData);
  final resolvedFollowUps = reviewers.resolvedThreadsWithReviewerReplies;
  prData['humanReviewers'] = reviewers.humanReviewers;
  prData['approvedReviewers'] = reviewers.approvedReviewers;

  print('Fetching check runs...');
  final checks = await fetchPrChecks(context);
  final failedChecks = checks.where((c) => c.isFail).toList();
  final pendingChecks = checks.where((c) => c.isPending).toList();

  final headSha = prData['headRefOid']?.toString() ?? '';
  final checkLogs = await _fetchFailedCheckLogs(context, failedChecks, headSha);

  return (
    (
      prData: prData,
      syncStatus: syncStatus,
      unresolvedThreads: unresolvedThreads,
      reviewComments: reviewComments,
      generalComments: generalComments,
      failedChecks: failedChecks,
      pendingChecks: pendingChecks,
      checkLogs: checkLogs,
    ),
    conflictAnalysis,
    resolvedFollowUps,
  );
}

Future<Map<String, String>> _fetchFailedCheckLogs(
  PrContext context,
  List<PrCheckRun> failedChecks,
  String headSha,
) async {
  final checkLogs = <String, String>{};
  for (final check in failedChecks) {
    final checkName = check.name;
    print('Fetching failed logs for check "$checkName"...');
    try {
      final logOutput = await fetchFailedCheckLog(
        context,
        check,
        headSha: headSha,
      );
      checkLogs[checkName] = truncateLog(logOutput);
    } catch (e) {
      checkLogs[checkName] = 'Failed to fetch logs: $e';
    }
  }
  return checkLogs;
}
