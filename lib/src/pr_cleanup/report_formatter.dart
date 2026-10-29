import 'dart:convert';

import 'package:path/path.dart' as p;

import '../gh_view.dart' show formatTouchedMarkdown;
import 'models.dart';

/// Formats the PR sweep report as concise Markdown.
String formatMarkdownReport(PrSweepResult result, {bool applied = false}) {
  final buffer = StringBuffer();

  final header = applied
      ? '# 🧹 PR & Worktree Cleanup Sweep [🚀 Applied Pruning]'
      : '# 🧹 PR & Worktree Cleanup Sweep Overview';
  buffer
    ..writeln(header)
    ..writeln();

  _formatSummaryTable(buffer, result);
  _formatReadyToPruneSection(buffer, result.readyToPrune);
  _formatActiveSection(buffer, result.active, now: result.timestamp);
  _formatNeedsTriageSection(buffer, result.needsTriage);
  _formatLockedWorktreesSection(
    buffer,
    result.lockedWorktrees,
    now: result.timestamp,
  );
  _formatLandedIdsSection(buffer, result.candidateLandedIds);

  return buffer.toString().trimRight();
}

void _formatSummaryTable(StringBuffer buffer, PrSweepResult result) {
  final pruneWorktrees = result.readyToPrune
      .where((i) => i.worktreePath != null)
      .length;
  final activeWorktrees = result.active
      .where((i) => i.worktreePath != null)
      .length;
  final triageWorktrees = result.needsTriage
      .where((i) => i.worktreePath != null)
      .length;

  buffer
    ..writeln('## 📊 High-Level Summary')
    ..writeln()
    ..writeln('| Category | Worktrees | Items | Description |')
    ..writeln('| :--- | :--- | :--- | :--- |')
    ..writeln(
      '| **Ready to Prune** | $pruneWorktrees | '
      '${result.readyToPrune.length} | Landed PRs & merged Gerrit CLs |',
    )
    ..writeln(
      '| **Active / In-Flight** | $activeWorktrees | '
      '${result.active.length} | Open PRs & active Gerrit CLs |',
    )
    ..writeln(
      '| **Needs Triage** | $triageWorktrees | '
      '${result.needsTriage.length} | '
      'Unlocked unlinked worktrees & unmerged commits |',
    )
    ..writeln(
      '| **Locked Worktrees (FYI)** | ${result.lockedWorktrees.length} | '
      '${result.lockedWorktrees.length} | '
      'Safe-kept local worktrees (`git worktree lock`) |',
    )
    ..writeln();
}

void _formatReadyToPruneSection(
  StringBuffer buffer,
  List<PrunableItem> readyToPrune,
) {
  buffer
    ..writeln('## ✅ Ready to Prune')
    ..writeln();
  if (readyToPrune.isEmpty) {
    buffer.writeln('*Zero worktrees or branches ready for immediate pruning.*');
    return;
  }

  final byRepo = <String, List<PrunableItem>>{};
  for (final item in readyToPrune) {
    (byRepo[item.repository] ??= []).add(item);
  }

  for (final entry in byRepo.entries) {
    buffer.writeln('- **`${entry.key}`**:');
    for (final item in entry.value) {
      buffer.writeln(_formatPrunableItemLine(item));
    }
  }
}

String _formatPrunableItemLine(PrunableItem item) {
  final wtPart = item.worktreePath != null
      ? ' [`${p.basename(item.worktreePath!)}`](file://${item.worktreePath})'
      : '';
  final branchPart = ' branch `${item.branch}`';
  final prPart = _formatItemPrOrCl(item.source, item.prOrClNumber);
  final idPrefix = prPart.isNotEmpty ? '**$prPart**: ' : '';
  return '  - $idPrefix$wtPart$branchPart';
}

String _formatItemPrOrCl(String source, int? number) {
  if (number == null) return '';
  return source == 'gerrit' ? 'CL $number' : '#$number';
}

void _formatActiveSection(
  StringBuffer buffer,
  List<ActiveItem> active, {
  required DateTime now,
}) {
  buffer
    ..writeln()
    ..writeln('## 🚫 Active / Hands-Off')
    ..writeln();
  if (active.isEmpty) {
    buffer.writeln('*Zero open PRs or active CLs found.*');
    return;
  }

  buffer
    ..writeln(
      '| Target | Repository | Title | Status & Badges | Opened / Touched | '
      'Local Worktree |',
    )
    ..writeln('| :--- | :--- | :--- | :--- | :--- | :--- |');
  for (final item in active) {
    final idLabel = _formatItemPrOrCl(item.source, item.number);
    final link = '[**$idLabel**](${item.url})';
    final badges =
        'CI:&nbsp;${item.ciBadge}<br>Review:&nbsp;${item.reviewBadge}';
    final dates = _formatActiveDates(item, now);
    final wt = item.worktreePath != null
        ? '[`${p.basename(item.worktreePath!)}`](file://${item.worktreePath})'
        : '⚪ None';
    final cleanTitle = item.title.replaceAll('|', r'\|');
    buffer.writeln(
      '| $link | `${item.repository}` | $cleanTitle | $badges | $dates | '
      '$wt |',
    );
  }
}

String _formatActiveDates(ActiveItem item, DateTime now) {
  final parts = <String>[];
  if (item.createdAt != null) {
    parts.add('Opened:&nbsp;${_formatIsoDate(item.createdAt!)}');
  }
  if (item.updatedAt != null) {
    final touched = formatTouchedMarkdown(
      item.updatedAt!,
      currentTime: now,
    ).replaceAll(' ', '&nbsp;');
    parts.add('Touched:&nbsp;$touched');
  }
  return parts.isEmpty ? '⚪ None' : parts.join('<br>');
}

String _formatIsoDate(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

void _formatLockedWorktreesSection(
  StringBuffer buffer,
  List<LockedWorktreeItem> lockedWorktrees, {
  required DateTime now,
}) {
  if (lockedWorktrees.isEmpty) return;

  buffer
    ..writeln()
    ..writeln('## 📌 Locked Worktrees (FYI — Safe-Kept Local Work)')
    ..writeln()
    ..writeln(
      '*Safe-kept via `git worktree lock --reason`. Review periodically and '
      'run `git worktree unlock <path>` when ready to prune.*',
    )
    ..writeln()
    ..writeln(
      '| Repository | Worktree & Branch | Lock Reason | Commits Ahead | '
      'Last Touched |',
    )
    ..writeln('| :--- | :--- | :--- | :---: | :--- |');
  for (final item in lockedWorktrees) {
    buffer.writeln(_formatLockedWorktreeRow(item, now));
  }
}

String _formatLockedWorktreeRow(LockedWorktreeItem item, DateTime now) {
  final wtLink =
      '[`${p.basename(item.worktreePath)}`](file://${item.worktreePath}) '
      '(`${item.branch}`)';
  final reason = (item.lockReason != null && item.lockReason!.isNotEmpty)
      ? item.lockReason!.replaceAll('|', r'\|')
      : '⚠️ *(No --reason provided)*';
  final ahead = '${item.commitsAhead ?? '?'}';
  final touched = _formatLockedTouched(item, now);
  return '| `${item.repository}` | $wtLink | $reason | $ahead | $touched |';
}

String _formatLockedTouched(LockedWorktreeItem item, DateTime now) {
  if (item.updatedAt != null) {
    final iso = _formatIsoDate(item.updatedAt!);
    final badge = formatTouchedMarkdown(
      item.updatedAt!,
      currentTime: now,
    ).replaceAll(' ', '&nbsp;');
    return '$iso<br>$badge';
  }
  return item.lastCommitDate ?? '⚪ Unknown';
}

void _formatNeedsTriageSection(
  StringBuffer buffer,
  List<TriageItem> needsTriage,
) {
  if (needsTriage.isEmpty) return;

  buffer
    ..writeln()
    ..writeln('## ⚠️ Needs Triage')
    ..writeln()
    ..writeln(
      '*Triage dangling worktrees by either deleting them or locking them '
      'for safekeeping with a descriptive project/context reason '
      '(`git -C <repo> worktree lock --reason "<project & why kept>" '
      '<worktree>`).*',
    )
    ..writeln()
    ..writeln('| Target | Repository | Branch / Worktree | Reason |')
    ..writeln('| :--- | :--- | :--- | :--- |');
  for (final item in needsTriage) {
    final idLabel = item.prOrClNumber != null
        ? _formatItemPrOrCl(item.source, item.prOrClNumber)
        : '⚪';
    final loc = item.worktreePath != null
        ? '[`${p.basename(item.worktreePath!)}`](file://${item.worktreePath})'
        : '`${item.branch}`';
    buffer.writeln(
      '| $idLabel | `${item.repository}` | $loc | ${item.reason} |',
    );
  }
}

void _formatLandedIdsSection(
  StringBuffer buffer,
  List<int> candidateLandedIds,
) {
  if (candidateLandedIds.isEmpty) return;

  final handles = candidateLandedIds.map((id) => '#$id').join(', ');
  buffer
    ..writeln()
    ..writeln('### 💡 Landed PR/CL IDs for Task Reconciliation')
    ..writeln('Candidate landed handles: `$handles`');
}

/// Formats the PR sweep report as JSON.
String formatJsonReport(
  PrSweepResult result, {
  bool applied = false,
  PrCleanupApplyResult? applyResult,
}) {
  final map = {
    'applied': applied,
    if (applyResult != null) 'applyResult': applyResult.toJson(),
    ...result.toJson(),
  };
  return const JsonEncoder.withIndent('  ').convert(map);
}
