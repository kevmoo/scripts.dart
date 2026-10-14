import 'dart:convert';

import 'package:path/path.dart' as p;

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
  _formatBucketBSection(buffer, result.bucketB);
  _formatBucketASection(buffer, result.bucketA);
  _formatBucketCSection(buffer, result.bucketC);
  _formatLandedIdsSection(buffer, result.candidateLandedIds);

  return buffer.toString().trimRight();
}

void _formatSummaryTable(StringBuffer buffer, PrSweepResult result) {
  final bWorktrees = result.bucketB.where((i) => i.worktreePath != null).length;
  final aWorktrees = result.bucketA.where((i) => i.worktreePath != null).length;
  final cWorktrees = result.bucketC.where((i) => i.worktreePath != null).length;

  buffer
    ..writeln('## 📊 High-Level Summary')
    ..writeln()
    ..writeln('| Category | Worktrees | Items | Description |')
    ..writeln('| :--- | :--- | :--- | :--- |')
    ..writeln(
      '| **Bucket B (Safe to Prune)** | $bWorktrees | '
      '${result.bucketB.length} | Landed PRs & merged Gerrit CLs |',
    )
    ..writeln(
      '| **Bucket A (Active / In-Flight)** | $aWorktrees | '
      '${result.bucketA.length} | Open PRs & active Gerrit CLs |',
    )
    ..writeln(
      '| **Bucket C (Needs Confirmation)** | $cWorktrees | '
      '${result.bucketC.length} | Dirty worktrees & unmerged commits |',
    )
    ..writeln();
}

void _formatBucketBSection(StringBuffer buffer, List<BucketBItem> bucketB) {
  buffer
    ..writeln('## ✅ Bucket B — Safe to Prune Immediately')
    ..writeln();
  if (bucketB.isEmpty) {
    buffer.writeln('*Zero worktrees or branches ready for immediate pruning.*');
    return;
  }

  final byRepo = <String, List<BucketBItem>>{};
  for (final item in bucketB) {
    (byRepo[item.repository] ??= []).add(item);
  }

  for (final entry in byRepo.entries) {
    buffer.writeln('- **`${entry.key}`**:');
    for (final item in entry.value) {
      buffer.writeln(_formatBucketBItemLine(item));
    }
  }
}

String _formatBucketBItemLine(BucketBItem item) {
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

void _formatBucketASection(StringBuffer buffer, List<BucketAItem> bucketA) {
  buffer
    ..writeln()
    ..writeln('## 🚫 Bucket A — Active / Hands-Off')
    ..writeln();
  if (bucketA.isEmpty) {
    buffer.writeln('*Zero open PRs or active CLs found.*');
    return;
  }

  buffer
    ..writeln(
      '| Target | Repository | Title | Status & Badges | Local Worktree |',
    )
    ..writeln('| :--- | :--- | :--- | :--- | :--- |');
  for (final item in bucketA) {
    final idLabel = _formatItemPrOrCl(item.source, item.number);
    final link = '[**$idLabel**](${item.url})';
    final badges =
        'CI:&nbsp;${item.ciBadge}<br>Review:&nbsp;${item.reviewBadge}';
    final wt = item.worktreePath != null
        ? '[`${p.basename(item.worktreePath!)}`](file://${item.worktreePath})'
        : '⚪ None';
    final cleanTitle = item.title.replaceAll('|', r'\|');
    buffer.writeln(
      '| $link | `${item.repository}` | $cleanTitle | $badges | $wt |',
    );
  }
}

void _formatBucketCSection(StringBuffer buffer, List<BucketCItem> bucketC) {
  if (bucketC.isEmpty) return;

  buffer
    ..writeln()
    ..writeln('## ⚠️ Bucket C — Requires Explicit Confirmation')
    ..writeln()
    ..writeln('| Target | Repository | Branch / Worktree | Reason |')
    ..writeln('| :--- | :--- | :--- | :--- |');
  for (final item in bucketC) {
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
String formatJsonReport(PrSweepResult result, {bool applied = false}) {
  final map = {'applied': applied, ...result.toJson()};
  return const JsonEncoder.withIndent('  ').convert(map);
}
