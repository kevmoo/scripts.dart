import 'dart:convert';
import 'dart:io';

import 'package:io/ansi.dart';
import 'package:io/io.dart';

import '../shared/gh_args.dart';

/// Exception thrown by Gerrit View tool operations.
class GerritViewException extends CliException {
  const new(super.message, {super.exitCode = 1});
}

typedef CommitDetails = ({
  String sha,
  String relativeDate,
  String changeId,
  String rawBody,
});

typedef ThreadSummary = ({
  int totalThreads,
  int unresolvedReviewerLeaves,
  int unresolvedAuthorLeaves,
});

typedef RemoteCL = ({
  int number,
  String changeId,
  String subject,
  String status,
  String currentRevision,
  int currentRevisionNumber,
  String lastAuthorTouch,
  List<String> reviewers,
  List<String> crVotes,
  String cqStatus,
  ThreadSummary threads,
  String nextAction,
});

enum AlignmentState { inSync, contentIdentical, diverged }

typedef AlignmentResult = ({AlignmentState state, String display});

enum ClStatus {
  newCl('NEW'),
  merged('MERGED'),
  abandoned('ABANDONED'),
  unknown('UNKNOWN');

  final String value;
  new(this.value);
  static ClStatus parse(String raw) {
    final normalized = raw.toUpperCase();
    return ClStatus.values.firstWhere(
      (s) => s.value == normalized,
      orElse: () => ClStatus.unknown,
    );
  }
}

typedef CleanupSafety = ({bool isSafe, List<String> unmergedShas});

String _findRootCommentId(String id, Map<String, String> parentById) {
  var current = id;
  final visited = <String>{current};
  while (true) {
    final parent = parentById[current];
    if (parent == null || parent.isEmpty || !visited.add(parent)) break;
    current = parent;
  }
  return current;
}

Map<String, List<Map<String, dynamic>>> _groupCommentsByRoot(
  Map<String, dynamic> commentsByFile,
) {
  final allComments = <Map<String, dynamic>>[];
  final parentById = <String, String>{};

  for (final fileList in commentsByFile.values) {
    if (fileList is! List) continue;
    for (final item in fileList) {
      if (item is! Map<String, dynamic>) continue;
      allComments.add(item);
      final id = item['id'] as String? ?? '';
      final parentId = item['in_reply_to'] as String? ?? '';
      if (id.isNotEmpty && parentId.isNotEmpty) {
        parentById[id] = parentId;
      }
    }
  }

  final threadsByRoot = <String, List<Map<String, dynamic>>>{};
  for (var i = 0; i < allComments.length; i++) {
    final comment = allComments[i];
    final id = comment['id'] as String? ?? 'anon_$i';
    final rootId = _findRootCommentId(id, parentById);
    (threadsByRoot[rootId] ??= []).add(comment);
  }
  return threadsByRoot;
}

/// Reconstructs Gerrit `in_reply_to` comment trees by root ancestor ID and
/// evaluates the latest comment in each root thread so sibling replies and
/// resolved parent comments match Gerrit's native unresolved thread state.
ThreadSummary parseGerritCommentsJson(
  Map<String, dynamic> commentsByFile,
  int? ownerId,
) {
  final threadsByRoot = _groupCommentsByRoot(commentsByFile);

  var unresolvedReviewerLeaves = 0;
  var unresolvedAuthorLeaves = 0;

  for (final thread in threadsByRoot.values) {
    thread.sort(
      (a, b) => (a['updated'] as String? ?? '').compareTo(
        b['updated'] as String? ?? '',
      ),
    );
    final latest = thread.last;
    if (latest['unresolved'] != true) continue;

    final authorMap = latest['author'] as Map<String, dynamic>?;
    final authorId = authorMap?['_account_id'] as int?;
    if (ownerId != null && authorId == ownerId) {
      unresolvedAuthorLeaves++;
    } else {
      unresolvedReviewerLeaves++;
    }
  }

  return (
    totalThreads: threadsByRoot.length,
    unresolvedReviewerLeaves: unresolvedReviewerLeaves,
    unresolvedAuthorLeaves: unresolvedAuthorLeaves,
  );
}

String computeGerritNextAction({
  required List<String> reviewers,
  required List<String> crVotes,
  required String cqStatus,
  required ThreadSummary threads,
}) {
  if (threads.unresolvedReviewerLeaves > 0) {
    final count = threads.unresolvedReviewerLeaves;
    return '❌ Address $count unresolved reviewer comment(s)';
  }
  if (crVotes.any((v) => v.endsWith(':-1') || v.endsWith(':-2'))) {
    return '❌ Address negative Code-Review (${crVotes.join(', ')})';
  }
  if (cqStatus.startsWith('❌')) {
    return '❌ Fix failing CQ tryjobs';
  }
  if (threads.unresolvedAuthorLeaves > 0) {
    final target = reviewers.isEmpty ? 'Reviewer' : reviewers.join(', ');
    return '🔔 Ping $target (${threads.unresolvedAuthorLeaves} open thread(s))';
  }
  if (crVotes.any((v) => v.endsWith(':+1') || v.endsWith(':+2'))) {
    return '🚀 Approved (${crVotes.join(', ')})';
  }
  if (reviewers.isEmpty) {
    return '⚠️ Add Reviewer (0 assigned)';
  }
  return '⏳ Awaiting Review (${reviewers.join(', ')})';
}

List<String> _extractReviewers(Map<String, dynamic> item, int? ownerId) {
  final reviewersMap = item['reviewers'] as Map<String, dynamic>?;
  final list = reviewersMap?['REVIEWER'] as List<dynamic>? ?? const [];
  final names = <String>[];
  for (final r in list) {
    if (r is! Map<String, dynamic>) continue;
    if (ownerId != null && r['_account_id'] == ownerId) continue;
    final name = (r['name'] ?? r['email'] ?? '').toString().trim();
    if (name.isNotEmpty) names.add(name);
  }
  return names;
}

List<String> _extractCrVotes(Map<String, dynamic> item, int? ownerId) {
  final labels = item['labels'] as Map<String, dynamic>?;
  final cr = labels?['Code-Review'] as Map<String, dynamic>?;
  final all = cr?['all'] as List<dynamic>? ?? const [];
  final votes = <String>[];
  for (final v in all) {
    if (v is! Map<String, dynamic>) continue;
    if (ownerId != null && v['_account_id'] == ownerId) continue;
    final val = v['value'] as int? ?? 0;
    if (val == 0) continue;
    final name = (v['name'] ?? v['email'] ?? '?').toString().trim();
    final sign = val > 0 ? '+$val' : '$val';
    votes.add('$name:$sign');
  }
  return votes;
}

bool _hasActiveCqVote(Map<String, dynamic> item) {
  final labels = item['labels'] as Map<String, dynamic>?;
  final cq = labels?['Commit-Queue'] as Map<String, dynamic>?;
  final all = cq?['all'] as List<dynamic>? ?? const [];
  return all.any(
    (v) => v is Map<String, dynamic> && (v['value'] as int? ?? 0) > 0,
  );
}

String _nextCqStatus(
  String current,
  String msg,
  String date,
  bool activeCqVote,
) {
  if (msg.contains('This CL has passed the run')) return '✅ Passed ($date)';
  if (msg.contains('This CL has failed the run')) return '❌ Failed ($date)';
  if (msg.contains('-Commit-Queue') && current.startsWith('⏳')) return 'None';
  if (msg.contains('Dry run: CV is trying the patch') && activeCqVote) {
    return '⏳ Running ($date)';
  }
  return current;
}

(String, String) extractGerritMessagesTelemetry(
  Map<String, dynamic> item,
  int? ownerId,
  int currentRevisionNumber,
) {
  final created = (item['created'] as String? ?? '').split(' ').first;
  var lastAuthorTouch = created;
  var cqStatus = 'None';
  final activeCqVote = _hasActiveCqVote(item);

  final messages = item['messages'] as List<dynamic>? ?? const [];
  for (final m in messages) {
    if (m is! Map<String, dynamic>) continue;
    final date = (m['date'] as String? ?? '').split(' ').first;
    final effectiveAuthor =
        (m['real_author'] ?? m['author']) as Map<String, dynamic>?;
    if (ownerId != null &&
        effectiveAuthor?['_account_id'] == ownerId &&
        date.isNotEmpty) {
      lastAuthorTouch = date;
    }
    final rev = m['_revision_number'] as int? ?? currentRevisionNumber;
    if (rev != currentRevisionNumber) continue;
    final msg = m['message'] as String? ?? '';
    cqStatus = _nextCqStatus(cqStatus, msg, date, activeCqVote);
  }
  return (lastAuthorTouch, cqStatus);
}

ThreadSummary _fetchClCommentSummary(
  String actualRepoRoot,
  String gerritHost,
  int clNumber,
  int? ownerId,
) {
  final gobResult = Process.runSync('gob-curl', [
    'https://$gerritHost/changes/$clNumber/comments',
  ], workingDirectory: actualRepoRoot);
  if (gobResult.exitCode != 0) {
    return (
      totalThreads: 0,
      unresolvedReviewerLeaves: 0,
      unresolvedAuthorLeaves: 0,
    );
  }
  final cleaned = (gobResult.stdout as String)
      .trim()
      .replaceFirst(")]}'", '')
      .trim();
  try {
    final decoded = jsonDecode(cleaned);
    if (decoded is Map<String, dynamic>) {
      return parseGerritCommentsJson(decoded, ownerId);
    }
  } catch (_) {}
  return (
    totalThreads: 0,
    unresolvedReviewerLeaves: 0,
    unresolvedAuthorLeaves: 0,
  );
}

RemoteCL? _parseRemoteClItem(
  Map<String, dynamic> item,
  String actualRepoRoot,
  String gerritHost,
) {
  if (item case {
    '_number': final int number,
    'change_id': final String changeId,
    'subject': final String subject,
    'status': final String status,
    'current_revision': final String currentRevision,
    'revisions': final Map<String, dynamic> revisions,
  }) {
    final currentRevisionNumber =
        (revisions[currentRevision] as Map<String, dynamic>?)?['_number']
            as int? ??
        1;
    final ownerMap = item['owner'] as Map<String, dynamic>?;
    final ownerId = ownerMap?['_account_id'] as int?;
    final reviewers = _extractReviewers(item, ownerId);
    final crVotes = _extractCrVotes(item, ownerId);
    final (lastAuthorTouch, cqStatus) = extractGerritMessagesTelemetry(
      item,
      ownerId,
      currentRevisionNumber,
    );
    final threads = _fetchClCommentSummary(
      actualRepoRoot,
      gerritHost,
      number,
      ownerId,
    );
    final nextAction = computeGerritNextAction(
      reviewers: reviewers,
      crVotes: crVotes,
      cqStatus: cqStatus,
      threads: threads,
    );
    return (
      number: number,
      changeId: changeId,
      subject: subject,
      status: status,
      currentRevision: currentRevision,
      currentRevisionNumber: currentRevisionNumber,
      lastAuthorTouch: lastAuthorTouch,
      reviewers: reviewers,
      crVotes: crVotes,
      cqStatus: cqStatus,
      threads: threads,
      nextAction: nextAction,
    );
  }
  return null;
}

const _changesQuerySuffix =
    'changes/?q=owner:self+status:open'
    '&o=CURRENT_REVISION&o=DETAILED_LABELS&o=DETAILED_ACCOUNTS&o=MESSAGES';

Map<int, RemoteCL> fetchRemoteCLs(String actualRepoRoot, String gerritHost) {
  print(styleDim.wrap('Querying active CLs from Gerrit...')!);
  final gobResult = Process.runSync('gob-curl', [
    'https://$gerritHost/$_changesQuerySuffix',
  ], workingDirectory: actualRepoRoot);
  if (gobResult.exitCode != 0) {
    throw GerritViewException(
      'Failed to execute gob-curl. Is it in your PATH and authenticated?\n'
      'Error: ${gobResult.stderr}',
      exitCode: ExitCode.software.code,
    );
  }

  final rawJson = (gobResult.stdout as String).trim();
  final cleanedJson = rawJson.replaceFirst(")]}'", '').trim();

  List<dynamic> clList;
  try {
    clList = jsonDecode(cleanedJson) as List<dynamic>;
  } catch (e) {
    throw GerritViewException(
      'Failed to parse Gerrit response: $e\nRaw output:\n$cleanedJson',
      exitCode: ExitCode.software.code,
    );
  }

  final remoteCLs = <int, RemoteCL>{};
  for (final item in clList) {
    if (item is! Map<String, dynamic>) continue;
    final parsed = _parseRemoteClItem(item, actualRepoRoot, gerritHost);
    if (parsed != null) {
      remoteCLs[parsed.number] = parsed;
    }
  }
  return remoteCLs;
}

String? _buildClosedClQuery(List<int> clNumbers, Set<String> changeIds) {
  final issueTerms = clNumbers.map((n) => 'change:$n').join('+OR+');
  final cidTerms = changeIds.map((c) => 'change:$c').join('+OR+');
  if (issueTerms.isNotEmpty && cidTerms.isNotEmpty) {
    return '($issueTerms)+OR+(owner:self+($cidTerms))';
  }
  if (cidTerms.isNotEmpty) return 'owner:self+($cidTerms)';
  if (issueTerms.isNotEmpty) return issueTerms;
  return null;
}

Map<int, ClStatus> resolveClosedAndUnmappedCLs(
  String repoPath,
  Map<String, int> localBranchIssues,
  Map<String, CommitDetails> branchDetails,
  Map<int, RemoteCL> remoteCLs,
  String defaultBranch,
  String gerritHost,
) {
  final closedIssues = localBranchIssues.values
      .where((i) => !remoteCLs.containsKey(i))
      .toSet()
      .toList();
  final unmappedChangeIds = <String>{
    for (final entry in branchDetails.entries)
      if (entry.key != defaultBranch &&
          !localBranchIssues.containsKey(entry.key) &&
          entry.value.changeId.isNotEmpty)
        entry.value.changeId,
  };

  final statuses = <int, ClStatus>{};
  final query = _buildClosedClQuery(closedIssues, unmappedChangeIds);
  if (query == null) return statuses;

  final result = Process.runSync('gob-curl', [
    'https://$gerritHost/changes/?q=$query',
  ], workingDirectory: repoPath);
  if (result.exitCode != 0) return statuses;

  final cleanedJson = (result.stdout as String)
      .trim()
      .replaceFirst(")]}'", '')
      .trim();
  final issueByChangeId = <String, int>{};
  try {
    final list = jsonDecode(cleanedJson) as List<dynamic>;
    for (final item in list) {
      if (item case {
        '_number': final int number,
        'status': final String status,
        'change_id': final String changeId,
      }) {
        statuses[number] = ClStatus.parse(status);
        issueByChangeId[changeId] = number;
      }
    }
  } catch (_) {}

  for (final entry in branchDetails.entries) {
    if (entry.key == defaultBranch) continue;
    final matchedIssue = issueByChangeId[entry.value.changeId];
    if (matchedIssue != null) {
      localBranchIssues.putIfAbsent(entry.key, () => matchedIssue);
    }
  }
  return statuses;
}
