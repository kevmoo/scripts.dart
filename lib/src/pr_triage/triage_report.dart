import '../shared/graphql_utils.dart' show isBotLogin;
import 'fetch_pr_sync_status.dart';
import 'github_cli.dart';

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

String _extractPrAuthorLogin(Map<String, dynamic> prData) =>
    switch (prData['author']) {
      {'login': final String login} => login,
      final String login => login,
      _ => '',
    };

bool _isNonAuthorHumanReviewer(String login, String prAuthor) =>
    login.isNotEmpty && login != prAuthor && !isBotLogin(login);

/// Filters resolved review threads whose final comment was authored by a
/// non-author human reviewer (so reviewer follow-up notes inside resolved
/// threads are surfaced during triage).
List<PrReviewThread> filterResolvedThreadsWithReviewerReplies(
  Iterable<PrReviewThread> reviewThreads, {
  required String prAuthor,
}) => reviewThreads.where((thread) {
  if (!thread.isResolved || thread.comments.isEmpty) return false;
  return _isNonAuthorHumanReviewer(thread.comments.last.author, prAuthor);
}).toList();

Set<String> _collectApprovedReviewers(
  Iterable<PrReview> reviews,
  String prAuthor,
) {
  final latestStateByReviewer = <String, String>{};
  for (final review in reviews) {
    if (!_isNonAuthorHumanReviewer(review.author, prAuthor)) continue;
    final previous = latestStateByReviewer[review.author];
    if (review.state.isNotEmpty &&
        (review.state != 'COMMENTED' || previous != 'APPROVED')) {
      latestStateByReviewer[review.author] = review.state;
    }
  }
  return latestStateByReviewer.entries
      .where((e) => e.value == 'APPROVED')
      .map((e) => e.key)
      .toSet();
}

/// Derives the non-author human reviewers who have not approved, the
/// reviewers whose latest review state is `APPROVED`, and the resolved threads
/// whose latest comment is a reviewer follow-up, from [graphData].
({
  List<String> humanReviewers,
  List<String> approvedReviewers,
  List<PrReviewThread> resolvedThreadsWithReviewerReplies,
})
summarizeReviewers(PrGraphData graphData, Map<String, dynamic> prData) {
  final prAuthor = _extractPrAuthorLogin(prData);
  return (
    resolvedThreadsWithReviewerReplies:
        filterResolvedThreadsWithReviewerReplies(
          graphData.reviewThreads,
          prAuthor: prAuthor,
        ),
    humanReviewers: _collectHumanReviewersFromGraphData(graphData, prAuthor),
    approvedReviewers: _collectApprovedReviewers(
      graphData.reviews,
      prAuthor,
    ).toList(),
  );
}

List<String> _collectHumanReviewersFromGraphData(
  PrGraphData graphData,
  String prAuthor,
) {
  final approved = _collectApprovedReviewers(graphData.reviews, prAuthor);
  final authors = <String>{
    ...graphData.reviews.map((r) => r.author),
    ...graphData.reviewThreads.expand((t) => t.comments.map((c) => c.author)),
  };
  return authors
      .where(
        (login) =>
            _isNonAuthorHumanReviewer(login, prAuthor) &&
            !approved.contains(login),
      )
      .toList();
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

String? _extractRequestId(Object? item) => switch (item) {
  final String s => s,
  {'login': final String s} => s,
  {'slug': final String s} => s,
  {'name': final String s} => s,
  _ => null,
};

List<String> _parseRequestedReviewerIds(Object? rawRequests) {
  if (rawRequests is! List) return const [];
  return rawRequests
      .map(_extractRequestId)
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .toList();
}

Set<String> _resolveApprovedReviewers(TriageData data, String prAuthor) {
  final explicitApproved = _prDataList(data.prData['approvedReviewers'])
      .toSet();
  final explicitUnapproved = data.prData.containsKey('approvedReviewers')
      ? _prDataList(data.prData['humanReviewers'])
            .where((r) => !explicitApproved.contains(r))
            .toSet()
      : const <String>{};
  return <String>{
    ...explicitApproved,
    ..._collectApprovedReviewers(
      data.reviewComments,
      prAuthor,
    ).where((r) => !explicitUnapproved.contains(r)),
  };
}

Set<String> _collectTriageHumanReviewers(TriageData data, String prAuthor) {
  final explicitList = _prDataList(data.prData['humanReviewers']);
  final approved = _resolveApprovedReviewers(data, prAuthor);
  final candidateAuthors = <String>{
    ...explicitList,
    ...data.reviewComments.map((r) => r.author),
    ...data.unresolvedThreads.expand((t) => t.comments.map((c) => c.author)),
  };
  return candidateAuthors
      .where(
        (login) =>
            _isNonAuthorHumanReviewer(login, prAuthor) &&
            !approved.contains(login),
      )
      .toSet();
}

List<String> _prDataList(Object? value) =>
    value is List ? value.map((e) => e.toString()).toList() : const [];

({List<String> requested, List<String> unrequestedHumans})
_extractTriageReviewerQueue(TriageData data) {
  final prData = data.prData;
  if (!prData.containsKey('reviewRequests') &&
      !prData.containsKey('humanReviewers')) {
    return (requested: const [], unrequestedHumans: const []);
  }

  final prAuthor = _extractPrAuthorLogin(prData);
  final requested = _parseRequestedReviewerIds(prData['reviewRequests']);
  final humanReviewers = _collectTriageHumanReviewers(data, prAuthor);
  final isApproved = prData['reviewDecision']?.toString() == 'APPROVED';
  final unrequestedHumans = isApproved
      ? const <String>[]
      : humanReviewers.where((r) => !requested.contains(r)).toList();
  return (requested: requested, unrequestedHumans: unrequestedHumans);
}

final _prUrlRepoRegex = RegExp(r'github\.com/([^/]+/[^/]+)/pull/\d+');

({String line, String warningBlock}) _formatReviewerQueueSection(
  ({List<String> requested, List<String> unrequestedHumans}) queue,
  Map<String, dynamic> prData,
) {
  final unrequested = queue.unrequestedHumans;
  final unrequestedMentions = unrequested.map((r) => '@$r').join(', ');
  final url = prData['url']?.toString() ?? '';
  final match = _prUrlRepoRegex.firstMatch(url);
  final repoFlag = match != null ? ' -R ${match.group(1)}' : '';
  final warningBlock = unrequested.isEmpty
      ? ''
      : '> [!IMPORTANT]\n'
            '>\n'
            '> **Reviewer Dropped from Queue**: $unrequestedMentions '
            'previously reviewed this PR and '
            '${unrequested.length == 1 ? 'was' : 'were'} removed from '
            '`reviewRequests`. Posting a comment (`PTAL`) will NOT put this '
            'PR back into their GitHub Review Queue (`review-requested:@me`). '
            'After pushing fixes and resolving threads, re-request review '
            'via:\n'
            '> `kscripts pr-triage re-request ${unrequested.join(',')} '
            '[--comment "<reply>"] '
            '[--dismiss <review_database_id> -m "<reason>"]`\n'
            '> (or `gh pr edit ${prData['number']}$repoFlag --add-reviewer '
            '${unrequested.join(',')}`)\n\n';

  if (!prData.containsKey('reviewRequests')) {
    return (line: '', warningBlock: warningBlock);
  }
  final requestedLabel = queue.requested.isEmpty
      ? 'None (`[]`)'
      : queue.requested.map((r) => '@$r').join(', ');
  final missingSuffix = unrequested.isEmpty
      ? ''
      : ' ⚠️ (Missing active reviewer: $unrequestedMentions)';
  return (
    line: '**Review Requests**: $requestedLabel$missingSuffix\n',
    warningBlock: warningBlock,
  );
}

String _formatReviewDecisionSection(
  TriageData data,
  ({List<String> requested, List<String> unrequestedHumans}) queue,
  Set<String> approved,
) {
  final prData = data.prData;
  final rawDecision = prData['reviewDecision'];
  final prAuthor = _extractPrAuthorLogin(prData);
  final humanReviewers = _collectTriageHumanReviewers(data, prAuthor);
  final isReReviewQueued =
      rawDecision == 'CHANGES_REQUESTED' &&
      humanReviewers.isNotEmpty &&
      queue.unrequestedHumans.isEmpty &&
      queue.requested.isNotEmpty;
  final suffix = isReReviewQueued
      ? ' (🟡 Re-review already requested in queue; awaiting reviewer sign-off)'
      : '';
  final approvedLine = approved.isEmpty
      ? ''
      : '**Approved By**: ${approved.map((r) => '@$r').join(', ')} ✅\n';
  return '**Review Decision**: `$rawDecision`$suffix\n$approvedLine';
}

String buildTriageReport(
  TriageData data, {
  PrConflictAnalysis? conflictAnalysis,
  List<PrReviewThread> resolvedThreadsWithReviewerReplies = const [],
}) {
  final prData = data.prData;
  final syncStatus = data.syncStatus;
  final conflict = conflictAnalysis ?? _defaultConflictAnalysis(prData);
  final prAuthor = _extractPrAuthorLogin(prData);
  final approvedReviewers = _resolveApprovedReviewers(data, prAuthor);
  final queue = _extractTriageReviewerQueue(data);
  final queueSection = _formatReviewerQueueSection(queue, prData);
  final reviewDecisionSection = _formatReviewDecisionSection(
    data,
    queue,
    approvedReviewers,
  );
  final syncWarningBlock = syncStatus.warning != null
      ? '> [!WARNING]\n>\n> ${syncStatus.warning}\n\n'
      : '';
  final conflictWarningBlock = conflict.isConflicting
      ? '> [!WARNING]\n'
            '>\n'
            '> **MERGE CONFLICT BLOCKER**: This PR has merge conflicts with '
            '`origin/${conflict.baseRefName}` (`mergeable: '
            '${conflict.mergeable}`, `mergeStateStatus: '
            '${conflict.mergeStateStatus}`) and cannot be merged until '
            'resolved.\n\n'
      : '';
  final localCommit = syncStatus.localHeadSha.isEmpty
      ? 'N/A'
      : syncStatus.localHeadSha;
  final mergeableBadge = _formatMergeableBadge(conflict, prData);
  final reviewRequestsLine = queueSection.line;
  final reviewerQueueWarningBlock = queueSection.warningBlock;

  final report = StringBuffer('''
# PR Triage Report: #${prData['number']} - ${prData['title']}

**URL**: [PR #${prData['number']}](${prData['url']})
**Branch**: `${prData['headRefName']}` ➔ `${conflict.baseRefName}`
**Remote Commit**: `${prData['headRefOid']}`
**Local Commit**: `$localCommit`
**Sync Status**: `${syncStatus.syncState}`${syncStatus.isSynced ? ' ✅' : ' ⚠️'}
$reviewDecisionSection$reviewRequestsLine**Mergeable**: $mergeableBadge

$syncWarningBlock$conflictWarningBlock$reviewerQueueWarningBlock''');

  if (conflict.isConflicting) {
    _writeMergeConflictsSection(report, conflict);
  }
  _writeUnresolvedThreads(report, data.unresolvedThreads);
  _writeResolvedThreadsWithReviewerReplies(
    report,
    resolvedThreadsWithReviewerReplies,
  );
  _writeReviewComments(
    report,
    data.reviewComments,
    requestedReviewers: queue.requested.toSet(),
    approvedReviewers: approvedReviewers,
  );
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

void _writeResolvedThreadsWithReviewerReplies(
  StringBuffer report,
  List<PrReviewThread> threads,
) {
  if (threads.isEmpty) return;

  report.write(
    '## Resolved Threads with Latest Reviewer Follow-Up '
    '(${threads.length}) 💬\n\n',
  );
  for (var i = 0; i < threads.length; i++) {
    final thread = threads[i];
    if (thread.comments.isEmpty) continue;

    final first = thread.comments.first;
    final last = thread.comments.last;
    final commentsMarkdown = thread.comments
        .map((c) => _formatBlockquoteComment(c.author, c.createdAt, c.body))
        .join('\n\n');

    _writeMarkdownItem(
      report,
      header:
          'Resolved Thread #${i + 1} (Thread `${thread.id}`, Latest Comment '
          '`${last.databaseId}` by @${last.author}): `${first.path}` '
          '(Line ${first.line})',
      url: last.url,
      bodyMarkdown: commentsMarkdown,
    );
  }
}

String _formatReviewQueueBadge(
  PrReview review, {
  required Set<String> requestedReviewers,
  required Set<String> approvedReviewers,
}) {
  if (review.state == 'APPROVED') return '';
  if (approvedReviewers.contains(review.author)) {
    return ' [✅ Superseded by Approval]';
  }
  if (requestedReviewers.contains(review.author)) {
    return ' [🟡 Re-review Requested in Queue]';
  }
  return '';
}

void _writeReviewComments(
  StringBuffer report,
  List<PrReview> reviewComments, {
  Set<String> requestedReviewers = const {},
  Set<String> approvedReviewers = const {},
}) {
  if (reviewComments.isEmpty) return;

  report.write('## Top-Level Review Comments (${reviewComments.length})\n\n');
  for (var i = 0; i < reviewComments.length; i++) {
    final review = reviewComments[i];
    final queueBadge = _formatReviewQueueBadge(
      review,
      requestedReviewers: requestedReviewers,
      approvedReviewers: approvedReviewers,
    );
    _writeMarkdownItem(
      report,
      header:
          'Review #${i + 1} (Review `${review.id}`, Database ID '
          '`${review.databaseId}`): `${review.state}` by '
          '@${review.author}$queueBadge',
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
    final (icon, suffix) = check.isActionRequired
        ? ('⚠️', ' (ACTION_REQUIRED)')
        : check.isCancelled
        ? ('🚫', ' (${check.state.toUpperCase()})')
        : ('❌', '');
    report.write('''
### $icon ${check.name}$suffix
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
