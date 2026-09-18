import 'dart:convert';

import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Renders human-readable colorized terminal output.
String renderTerminalReport(List<GhPr> prs, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final categorized = categorizePullRequests(prs);

  final buffer = StringBuffer()
    ..writeln('''
======================================================================
${styleBold.wrap('🐙 GITHUB PULL REQUEST OVERVIEW')}
======================================================================''');

  if (prs.isEmpty) {
    buffer.writeln('\nNo open pull requests found. 🎉\n');
    return buffer.toString();
  }

  _writeTerminalSection(
    buffer,
    title: green.wrap(styleBold.wrap('🚀 READY TO MERGE')!)!,
    subtitle: 'Approved by reviewers and all CI checks passing:',
    prs: categorized.readyToMerge,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: red.wrap(
      styleBold.wrap('⚠️  ACTION NEEDED (Blocked / Failing / Conflicts)')!,
    )!,
    subtitle: 'Requires code fixes, rebase, or review feedback resolution:',
    prs: categorized.actionNeeded,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: yellow.wrap(styleBold.wrap('🟡 IN REVIEW QUEUE')!)!,
    subtitle: 'Active PRs awaiting reviewer feedback:',
    prs: categorized.inReview,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: styleDim.wrap(styleBold.wrap('⚪ DRAFTS & WORK IN PROGRESS')!)!,
    subtitle: 'Work-in-progress draft pull requests:',
    prs: categorized.drafts,
    now: now,
  );

  _writeTerminalSection(
    buffer,
    title: styleDim.wrap(
      styleBold.wrap('📦 ARCHIVED REPOSITORIES (Read-Only)')!,
    )!,
    subtitle: 'Repositories are archived; pull requests cannot be modified:',
    prs: categorized.archived,
    now: now,
  );

  final summary =
      'Total Open: ${prs.length} | '
      '🚀 Ready: ${categorized.readyToMerge.length} | '
      '⚠️ Action: ${categorized.actionNeeded.length} | '
      '🟡 Review: ${categorized.inReview.length} | '
      '⚪ Drafts: ${categorized.drafts.length} | '
      '📦 Archived: ${categorized.archived.length}';

  buffer.writeln('''

----------------------------------------------------------------------
${styleBold.wrap('Summary:')} $summary
----------------------------------------------------------------------''');

  return buffer.toString();
}

void _writeTerminalSection(
  StringBuffer buffer, {
  required String title,
  required String subtitle,
  required List<GhPr> prs,
  required DateTime now,
}) {
  if (prs.isEmpty) return;
  buffer
    ..writeln('\n$title')
    ..writeln(styleDim.wrap('   $subtitle')!);
  for (final pr in prs) {
    _writePrItem(buffer, pr, now);
  }
}

void _writePrItem(StringBuffer buffer, GhPr pr, DateTime now) {
  final prTag =
      styleBold.wrap('${pr.repository}#${pr.number}') ??
      '${pr.repository}#${pr.number}';
  final touched = formatTouchedTerminal(pr.updatedAt, currentTime: now);

  final statusBadges = <String>[];
  if (pr.isRepoArchived) {
    statusBadges.add(styleDim.wrap('[Archived Repo]') ?? '[Archived Repo]');
  }
  if (pr.isDraft) {
    statusBadges.add(styleDim.wrap('[Draft]') ?? '[Draft]');
  }

  statusBadges
    ..add(_formatReviewBadgeTerminal(pr))
    ..add(_formatCiBadgeTerminal(pr));
  if (pr.isInMergeQueue) {
    statusBadges.add(cyan.wrap('🔀 In Merge Queue') ?? '🔀 In Merge Queue');
  }
  if (pr.isBlockedMergeState) {
    statusBadges.add(red.wrap('🧱 Blocked') ?? '🧱 Blocked');
  }
  if (pr.mergeable == MergeableState.conflicting) {
    statusBadges.add(red.wrap('⚠️ Conflicting') ?? '⚠️ Conflicting');
  }

  buffer
    ..writeln('\n  • $prTag: ${pr.title}')
    ..writeln('    URL:     ${pr.url}')
    ..writeln('    Status:  ${statusBadges.join(' | ')}')
    ..writeln('    Branch:  ${pr.headRefName} ➔ ${pr.baseRefName}')
    ..writeln('    Touched: $touched');

  if (pr.context != null && pr.context!.trim().isNotEmpty) {
    buffer.writeln('    Context: ${pr.context!.trim()}');
  }

  if (pr.localStatus != null) {
    final loc = pr.localStatus!;
    final locDesc = p.basename(loc.repoPath);
    final wtTag = loc.isWorktree ? ' (worktree)' : '';
    buffer.writeln(
      '    Local:   ${loc.displayStatus} [$locDesc$wtTag at ${loc.repoPath}]',
    );
  }
}

String _formatReviewBadgeTerminal(GhPr pr) {
  String formatRequested(String label) {
    if (pr.targetReviewers.isNotEmpty) {
      final text = '$label (@${pr.targetReviewers.join(', @')})';
      return yellow.wrap(text) ?? text;
    }
    return yellow.wrap(label) ?? label;
  }

  if (pr.reviewDecision == ReviewDecision.approved) {
    return green.wrap('Approved') ?? 'Approved';
  }
  if (pr.reviewDecision == ReviewDecision.changesRequested) {
    if (pr.targetReviewers.isNotEmpty) {
      return formatRequested('Re-review Requested');
    }
    if (pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0) {
      const text = 'Changes Requested (Resolved: Re-review Needed)';
      return yellow.wrap(text) ?? text;
    }
    return red.wrap('Changes Requested') ?? 'Changes Requested';
  }
  if (pr.reviewDecision == ReviewDecision.reviewRequired) {
    return formatRequested('Review Required');
  }
  return 'No Reviewers';
}

String _formatCiBadgeTerminal(GhPr pr) => switch (pr.ciStatus) {
  CiStatus.success => green.wrap('CI: Passing') ?? 'CI: Passing',
  CiStatus.treeBroken =>
    yellow.wrap('CI: Tree Broken (PR Clean)') ?? 'CI: Tree Broken (PR Clean)',
  CiStatus.failure => red.wrap('CI: Failing') ?? 'CI: Failing',
  CiStatus.pending => yellow.wrap('CI: Pending') ?? 'CI: Pending',
  _ => styleDim.wrap('CI: None') ?? 'CI: None',
};

/// Renders machine-readable JSON output.
String renderJsonOutput(List<GhPr> prs, {DateTime? currentTime}) {
  final now = currentTime ?? DateTime.now();
  final categorized = categorizePullRequests(prs);

  Map<String, dynamic> prToJson(GhPr pr) => {
    'number': pr.number,
    'title': pr.title,
    'url': pr.url,
    'author': pr.author,
    'repository': pr.repository,
    'repoUrl': pr.repoUrl,
    'isRepoArchived': pr.isRepoArchived,
    'isDraft': pr.isDraft,
    'state': pr.state,
    'reviewDecision': pr.reviewDecision,
    'requestedReviewers': pr.requestedReviewers,
    'activeReviewers': pr.activeReviewers,
    'targetReviewers': pr.targetReviewers,
    'isAlreadyPinged': pr.isAlreadyPinged,
    'lastAuthorCommentAt': pr.lastAuthorCommentAt?.toIso8601String(),
    'lastReviewerActivityAt': pr.lastReviewerActivityAt?.toIso8601String(),
    'totalReviewThreads': pr.totalReviewThreads,
    'unresolvedReviewThreads': pr.unresolvedReviewThreads,
    'areAllReviewThreadsResolved':
        pr.totalReviewThreads > 0 && pr.unresolvedReviewThreads == 0,
    'ciStatus': pr.ciStatus,
    'mergeable': pr.mergeable,
    'mergeStateStatus': pr.mergeStateStatus,
    'isInMergeQueue': pr.isInMergeQueue,
    'headRefName': pr.headRefName,
    'headRefOid': pr.headRefOid,
    'baseRefName': pr.baseRefName,
    'updatedAt': pr.updatedAt.toIso8601String(),
    'touched': formatTimeAgo(pr.updatedAt, currentTime: now),
    'context': pr.context,
    'local': pr.localStatus == null
        ? null
        : {
            'path': pr.localStatus!.repoPath,
            'branch': pr.localStatus!.branchName,
            'shortSha': pr.localStatus!.shortSha,
            'isDirty': pr.localStatus!.isDirty,
            'isHeadMatching': pr.localStatus!.isHeadMatching,
            'isWorktree': pr.localStatus!.isWorktree,
            'status': pr.localStatus!.displayStatus,
          },
  };

  final data = {
    'summary': {
      'total': prs.length,
      'readyToMerge': categorized.readyToMerge.length,
      'actionNeeded': categorized.actionNeeded.length,
      'inReview': categorized.inReview.length,
      'drafts': categorized.drafts.length,
      'archived': categorized.archived.length,
    },
    'readyToMerge': categorized.readyToMerge.map(prToJson).toList(),
    'actionNeeded': categorized.actionNeeded.map(prToJson).toList(),
    'inReview': categorized.inReview.map(prToJson).toList(),
    'drafts': categorized.drafts.map(prToJson).toList(),
    'archived': categorized.archived.map(prToJson).toList(),
  };

  return const JsonEncoder.withIndent('  ').convert(data);
}
