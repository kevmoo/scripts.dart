import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';

import 'pr_triage/github_cli.dart';
import 'shared/graphql_utils.dart' show isBotLogin;
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

ArgParser buildPrTriageArgParser() =>
    buildPrContextArgParser()..addCommand('resolve', buildPrContextArgParser());

void _printPrTriageUsage(ArgParser parser) {
  print(prTriageDescription);
  print('');
  print('Usage:');
  print('  kscripts pr-triage [options]');
  print(
    '  kscripts pr-triage resolve <thread_id> [<comment_id> "<body_text>"]',
  );
  print('');
  print('Options:');
  print(parser.usage);
}

Future<void> runPrTriageCli(List<String> args) async {
  final parser = buildPrTriageArgParser();
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
  final resolveCmd = results.command;
  if (resolveCmd != null && resolveCmd.name == 'resolve') {
    await _handleResolveCommand(results, resolveCmd);
    return;
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

  final (data, conflictAnalysis) = await _fetchTriageData(context);
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

typedef TriageData = ({
  Map<String, dynamic> prData,
  PrSyncStatus syncStatus,
  List<PrReviewThread> unresolvedThreads,
  List<PrReview> reviewComments,
  List<PrComment> generalComments,
  List<PrCheckRun> failedChecks,
  List<PrCheckRun> pendingChecks,
  Map<String, String> checkLogs,
});

const _prViewFields =
    'number,title,state,author,reviewDecision,reviewRequests,mergeable,'
    'mergeStateStatus,baseRefName,headRefName,headRefOid,url';

Future<(TriageData, PrConflictAnalysis)> _fetchTriageData(
  PrContext context,
) async {
  print(
    'Fetching details for PR #${context.prNumber} from '
    '${context.owner}/${context.repo}...',
  );
  print('Target directory: ${context.workingDir}');
  final viewOutput = await runCommand('gh', [
    '-R',
    '${context.owner}/${context.repo}',
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

  final prAuthor = switch (prData['author']) {
    {'login': final String login} => login,
    final String login => login,
    _ => '',
  };
  final humanReviewers = <String>{
    for (final r in graphData.reviews)
      if (r.author.isNotEmpty && r.author != prAuthor && !isBotLogin(r.author))
        r.author,
    for (final t in graphData.reviewThreads)
      for (final c in t.comments)
        if (c.author.isNotEmpty &&
            c.author != prAuthor &&
            !isBotLogin(c.author))
          c.author,
  };
  prData['humanReviewers'] = humanReviewers.toList();

  print('Fetching check runs...');
  final checks = await fetchPrChecks(context);
  final failedChecks = checks.where((c) => c.isFail).toList();
  final pendingChecks = checks.where((c) => c.isPending).toList();

  final checkLogs = await _fetchFailedCheckLogs(context, failedChecks);

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
  );
}

Future<Map<String, String>> _fetchFailedCheckLogs(
  PrContext context,
  List<PrCheckRun> failedChecks,
) async {
  final checkLogs = <String, String>{};
  for (final check in failedChecks) {
    final checkName = check.name;
    print('Fetching failed logs for check "$checkName"...');
    try {
      final logOutput = await fetchFailedCheckLog(context, check);
      checkLogs[checkName] = truncateLog(logOutput);
    } catch (e) {
      checkLogs[checkName] = 'Failed to fetch logs: $e';
    }
  }
  return checkLogs;
}

PrConflictAnalysis _defaultConflictAnalysis(Map<String, dynamic> prData) {
  final mergeable = prData['mergeable']?.toString() ?? 'UNKNOWN';
  final mergeStateStatus = prData['mergeStateStatus']?.toString() ?? 'UNKNOWN';
  return (
    isConflicting: mergeable == 'CONFLICTING' || mergeStateStatus == 'DIRTY',
    mergeable: mergeable,
    mergeStateStatus: mergeStateStatus,
    baseRefName: prData['baseRefName']?.toString() ?? 'main',
    headRefName: prData['headRefName']?.toString() ?? '',
    conflictingFiles: const <String>[],
    conflictMessages: const <String>[],
    upstreamCommits: const <String>[],
  );
}

String _formatMergeableBadge(
  PrConflictAnalysis conflict,
  Map<String, dynamic> prData,
) => switch (conflict.mergeable) {
  'MERGEABLE' => '`MERGEABLE` ✅',
  'CONFLICTING' => '`CONFLICTING` ⚠️ (BLOCKER)',
  _ =>
    conflict.isConflicting
        ? '`${conflict.mergeable}` ⚠️ (`${conflict.mergeStateStatus}`)'
        : '`${prData['mergeable']}`',
};

({List<String> requested, List<String> unrequestedHumans})
_extractTriageReviewerQueue(TriageData data) {
  final prData = data.prData;
  if (!prData.containsKey('reviewRequests') &&
      !prData.containsKey('humanReviewers')) {
    return (requested: const [], unrequestedHumans: const []);
  }

  final prAuthor = switch (prData['author']) {
    {'login': final String login} => login,
    final String login => login,
    _ => '',
  };

  final requested = <String>[];
  final rawRequests = prData['reviewRequests'];
  if (rawRequests is List) {
    for (final item in rawRequests) {
      final id = switch (item) {
        final String s => s,
        {'login': final String s} => s,
        {'slug': final String s} => s,
        {'name': final String s} => s,
        _ => null,
      };
      if (id != null && id.isNotEmpty) requested.add(id);
    }
  }

  final humanReviewers = <String>{
    if (prData['humanReviewers'] case final List<dynamic> list)
      ...list.map((e) => e.toString()),
    for (final r in data.reviewComments)
      if (r.author.isNotEmpty && r.author != prAuthor && !isBotLogin(r.author))
        r.author,
    for (final t in data.unresolvedThreads)
      for (final c in t.comments)
        if (c.author.isNotEmpty &&
            c.author != prAuthor &&
            !isBotLogin(c.author))
          c.author,
  };

  final isApproved = prData['reviewDecision']?.toString() == 'APPROVED';
  final unrequestedHumans = isApproved
      ? const <String>[]
      : humanReviewers.where((r) => !requested.contains(r)).toList();
  return (requested: requested, unrequestedHumans: unrequestedHumans);
}

String buildTriageReport(
  TriageData data, {
  PrConflictAnalysis? conflictAnalysis,
}) {
  final prData = data.prData;
  final syncStatus = data.syncStatus;
  final conflict = conflictAnalysis ?? _defaultConflictAnalysis(prData);
  final reviewerQueue = _extractTriageReviewerQueue(data);
  final syncWarningBlock = syncStatus.warning != null
      ? '> [!WARNING]\n> ${syncStatus.warning}\n\n'
      : '';
  final conflictWarningBlock = conflict.isConflicting
      ? '> [!WARNING]\n'
            '> **MERGE CONFLICT BLOCKER**: This PR has merge conflicts with '
            '`origin/${conflict.baseRefName}` (`mergeable: '
            '${conflict.mergeable}`, `mergeStateStatus: '
            '${conflict.mergeStateStatus}`) and cannot be merged until '
            'resolved.\n\n'
      : '';
  final unrequested = reviewerQueue.unrequestedHumans;
  final reviewerQueueWarningBlock = unrequested.isNotEmpty
      ? '> [!IMPORTANT]\n'
            '> **Reviewer Dropped from Queue**: '
            '${unrequested.map((r) => '@$r').join(', ')} previously reviewed '
            'this PR and ${unrequested.length == 1 ? 'was' : 'were'} removed '
            'from `reviewRequests`. Posting a comment (`PTAL`) will NOT put '
            'this PR back into their GitHub Review Queue '
            '(`review-requested:@me`). After pushing fixes and resolving '
            'threads, re-request review via:\n'
            '> `gh pr edit ${prData['number']} --add-reviewer '
            '${unrequested.join(',')}`\n\n'
      : '';
  final localCommit = syncStatus.localHeadSha.isEmpty
      ? 'N/A'
      : syncStatus.localHeadSha;
  final mergeableBadge = _formatMergeableBadge(conflict, prData);
  final requestedLabel = reviewerQueue.requested.isEmpty
      ? 'None (`[]`)'
      : reviewerQueue.requested.map((r) => '@$r').join(', ');
  final missingSuffix = unrequested.isNotEmpty
      ? ' ⚠️ (Missing active reviewer: '
            '${unrequested.map((r) => '@$r').join(', ')})'
      : '';
  final reviewRequestsLine = prData.containsKey('reviewRequests')
      ? '**Review Requests**: $requestedLabel$missingSuffix\n'
      : '';

  final report = StringBuffer('''
# PR Triage Report: #${prData['number']} - ${prData['title']}

**URL**: [PR #${prData['number']}](${prData['url']})
**Branch**: `${prData['headRefName']}` ➔ `${conflict.baseRefName}`
**Remote Commit**: `${prData['headRefOid']}`
**Local Commit**: `$localCommit`
**Sync Status**: `${syncStatus.syncState}`${syncStatus.isSynced ? ' ✅' : ' ⚠️'}
**Review Decision**: `${prData['reviewDecision']}`
$reviewRequestsLine**Mergeable**: $mergeableBadge

$syncWarningBlock$conflictWarningBlock$reviewerQueueWarningBlock''');

  if (conflict.isConflicting) {
    _writeMergeConflictsSection(report, conflict);
  }
  _writeUnresolvedThreads(report, data.unresolvedThreads);
  _writeReviewComments(report, data.reviewComments);
  _writeConversationComments(report, data.generalComments);
  _writeFailedChecks(
    report,
    data.failedChecks,
    data.checkLogs,
    conflict: conflict,
  );
  _writePendingChecks(report, data.pendingChecks);

  return report.toString();
}

void _writeMergeConflictsSection(
  StringBuffer report,
  PrConflictAnalysis conflict,
) {
  final fileCount = conflict.conflictingFiles.length;
  final countLabel = fileCount > 0 ? '$fileCount conflicting files' : 'Blocker';
  report.write('## ⚠️ Merge Conflicts ($countLabel)\n\n');

  if (conflict.conflictingFiles.isNotEmpty) {
    report.write('### Conflicting Files\n');
    for (final file in conflict.conflictingFiles) {
      report.write('- `$file`\n');
    }
    report.write('\n');
  } else {
    report.write(
      'GitHub reports `mergeable: ${conflict.mergeable}` '
      '(`mergeStateStatus: ${conflict.mergeStateStatus}`) against '
      '`origin/${conflict.baseRefName}`.\n\n',
    );
  }

  if (conflict.upstreamCommits.isNotEmpty) {
    report.write(
      '### Conflicting Upstream Commits on `origin/${conflict.baseRefName}`\n',
    );
    for (final commit in conflict.upstreamCommits) {
      report.write('- `$commit`\n');
    }
    report.write('\n');
  }

  report.write('''
### Recommended Conflict Resolution (No Force-Push)
```bash
git fetch origin ${conflict.baseRefName}
git merge origin/${conflict.baseRefName}
```

''');
}

String _formatBlockquoteComment(String author, String timestamp, String body) =>
    '''
**@$author** ($timestamp):
> ${body.replaceAll('\n', '\n> ')}''';

void _writeMarkdownItem(
  StringBuffer report, {
  required String header,
  required String url,
  required String bodyMarkdown,
}) {
  report.write('''
### $header
Link: $url

$bodyMarkdown

---

''');
}

void _writeUnresolvedThreads(
  StringBuffer report,
  List<PrReviewThread> unresolvedThreads,
) {
  report.write(
    '## Unresolved Review Comments (${unresolvedThreads.length})\n\n',
  );
  if (unresolvedThreads.isEmpty) {
    report.write('No unresolved review comments found! 🎉\n\n');
    return;
  }

  for (var i = 0; i < unresolvedThreads.length; i++) {
    final thread = unresolvedThreads[i];
    if (thread.comments.isEmpty) continue;

    final first = thread.comments.first;
    final commentsMarkdown = thread.comments
        .map((c) => _formatBlockquoteComment(c.author, c.createdAt, c.body))
        .join('\n\n');

    _writeMarkdownItem(
      report,
      header:
          'Comment #${i + 1} (Thread `${thread.id}`, Comment '
          '`${first.databaseId}`): `${first.path}` (Line ${first.line})',
      url: first.url,
      bodyMarkdown: commentsMarkdown,
    );
  }
}

void _writeReviewComments(StringBuffer report, List<PrReview> reviewComments) {
  if (reviewComments.isEmpty) return;

  report.write('## Top-Level Review Comments (${reviewComments.length})\n\n');
  for (var i = 0; i < reviewComments.length; i++) {
    final review = reviewComments[i];
    _writeMarkdownItem(
      report,
      header:
          'Review #${i + 1} (Review `${review.id}`, Database ID '
          '`${review.databaseId}`): `${review.state}` by @${review.author}',
      url: review.url,
      bodyMarkdown: _formatBlockquoteComment(
        review.author,
        review.submittedAt,
        review.body,
      ),
    );
  }
}

void _writeConversationComments(
  StringBuffer report,
  List<PrComment> generalComments,
) {
  if (generalComments.isEmpty) return;

  report.write('## Conversation Comments (${generalComments.length})\n\n');
  for (var i = 0; i < generalComments.length; i++) {
    final comment = generalComments[i];
    _writeMarkdownItem(
      report,
      header:
          'Conversation Comment #${i + 1} (Comment `${comment.databaseId}`) '
          'by @${comment.author}',
      url: comment.url,
      bodyMarkdown: _formatBlockquoteComment(
        comment.author,
        comment.createdAt,
        comment.body,
      ),
    );
  }
}

void _writeFailedChecks(
  StringBuffer report,
  List<PrCheckRun> failedChecks,
  Map<String, String> checkLogs, {
  PrConflictAnalysis? conflict,
}) {
  report.write('## Failed Status Checks (${failedChecks.length})\n\n');
  if (failedChecks.isEmpty) {
    if (conflict != null && conflict.isConflicting) {
      report.write(
        'All CI checks passing (✅), but PR is **BLOCKED BY MERGE CONFLICTS** '
        '(⚠️) with `origin/${conflict.baseRefName}`!\n\n',
      );
    } else {
      report.write('All checks passing! ✅\n\n');
    }
    return;
  }

  for (final check in failedChecks) {
    report.write('''
### ❌ ${check.name}
Link: ${check.link}

```text
${checkLogs[check.name] ?? 'No logs available.'}
```

''');
  }
}

void _writePendingChecks(StringBuffer report, List<PrCheckRun> pendingChecks) {
  if (pendingChecks.isEmpty) return;

  report.write(
    '## Active/Pending Status Checks (${pendingChecks.length}) ⏳\n\n',
  );
  for (final check in pendingChecks) {
    report.write('- ⏳ **${check.name}**: [Inspect Check Run](${check.link})\n');
  }
  report.write('\n');
}

String truncateLog(String log) {
  final lines = log.split('\n');
  if (lines.length <= 100) return log;
  final head = lines.take(15).join('\n');
  final tail = lines.sublist(lines.length - 85).join('\n');
  return '$head\n\n... [TRUNCATED ${lines.length - 100} LINES] ...\n\n$tail';
}
