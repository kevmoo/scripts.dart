import 'dart:convert';

import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import '../gh_clean.dart';

/// Renders and prints the `gh-clean` report according to [options].
void outputGhCleanReport(
  List<PrCleanResult> results,
  GhCleanOptions options, {
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) {
  if (options.json) {
    print(
      jsonEncode(
        formatJsonReport(
          results,
          applied: options.apply,
          unlinkedWorktrees: unlinkedWorktrees,
        ),
      ),
    );
  } else if (options.markdown) {
    print(
      formatMarkdownReport(
        results,
        applied: options.apply,
        unlinkedWorktrees: unlinkedWorktrees,
      ),
    );
  } else {
    printTerminalReport(
      results,
      applied: options.apply,
      unlinkedWorktrees: unlinkedWorktrees,
    );
  }
}

/// Formats output as GitHub Flavored Markdown.
///
/// Rows are sorted by `org` -> `repo` -> `oldest PR number`.
/// Actionable PRs (requiring worktree pruning or branch deletion) are rendered
/// as individual rows with their specific PR link and actions. PRs with no
/// local branch/worktree mutations are clustered into a single summary row
/// per repository.
String formatMarkdownReport(
  List<PrCleanResult> results, {
  required bool applied,
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) {
  final buffer = StringBuffer()
    ..writeln('# Landed Pull Requests Cleanup Report')
    ..writeln()
    ..writeln(
      applied
          ? '**Mode**: 🚀 Applied Cleanup'
          : '**Mode**: 🔍 Preview Mode (Dry Run)',
    )
    ..writeln();

  if (results.isEmpty) {
    buffer.writeln('No recently landed pull requests found.');
  } else {
    buffer
      ..writeln('<!-- mdformat off -->')
      ..writeln('| Repository | PR(s) | Local Directory | Actions / Status |')
      ..writeln('| :--- | :--- | :--- | :--- |');

    final rows = _buildSortedReportRows(results, applied: applied);
    for (final row in rows) {
      buffer.writeln(row.markdown);
    }

    buffer.writeln('<!-- mdformat on -->');
  }

  if (unlinkedWorktrees.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Worktrees with No Associated PR')
      ..writeln()
      ..writeln('<!-- mdformat off -->')
      ..writeln(
        '| Repository | Worktree | Branch | Commits Ahead | Last Commit |',
      )
      ..writeln('| :--- | :--- | :--- | :---: | :--- |');

    for (final u in unlinkedWorktrees) {
      final repoLink =
          '[**${u.repository}**](https://github.com/${u.repository})';
      final wtLink =
          '[`${p.basename(u.worktreePath)}`](file://${u.worktreePath})';
      final branchStr = '`${u.branch}`';
      final aheadStr = u.commitsAhead != null ? '${u.commitsAhead}' : '?';
      final dateStr = u.lastCommitDate ?? '?';
      buffer.writeln(
        '| $repoLink | $wtLink | $branchStr | $aheadStr | $dateStr |',
      );
    }

    buffer.writeln('<!-- mdformat on -->');
  }

  return buffer.toString();
}

List<_ReportRow> _buildSortedReportRows(
  List<PrCleanResult> results, {
  required bool applied,
}) {
  final repoMap = <String, List<PrCleanResult>>{};
  for (final r in results) {
    repoMap.putIfAbsent(r.pr.repository, () => []).add(r);
  }

  final rows = <_ReportRow>[];

  for (final entry in repoMap.entries) {
    final list = entry.value;
    final parts = entry.key.split('/');
    final org = parts.isNotEmpty ? parts[0] : '';
    final repo = parts.length > 1 ? parts[1] : '';

    final actionable = list.where(_hasLocalBranchOrWorktreeAction).toList()
      ..sort((a, b) => a.pr.number.compareTo(b.pr.number));
    final noOps =
        list.where((r) => !_hasLocalBranchOrWorktreeAction(r)).toList()
          ..sort((a, b) => a.pr.number.compareTo(b.pr.number));

    for (final r in actionable) {
      rows.add((
        org: org,
        repo: repo,
        minPrNumber: r.pr.number,
        markdown: _formatActionableMarkdownRow(r, applied: applied),
      ));
    }

    if (noOps.isNotEmpty) {
      rows.add((
        org: org,
        repo: repo,
        minPrNumber: noOps.first.pr.number,
        markdown: _formatNoOpClusterMarkdownRow(noOps, applied: applied),
      ));
    }
  }

  rows.sort((a, b) {
    final orgCmp = a.org.toLowerCase().compareTo(b.org.toLowerCase());
    if (orgCmp != 0) return orgCmp;
    final repoCmp = a.repo.toLowerCase().compareTo(b.repo.toLowerCase());
    if (repoCmp != 0) return repoCmp;
    return a.minPrNumber.compareTo(b.minPrNumber);
  });

  return rows;
}

typedef _ReportRow = ({
  String org,
  String repo,
  int minPrNumber,
  String markdown,
});

bool _hasLocalBranchOrWorktreeAction(PrCleanResult r) =>
    r.plannedActions.any(
      (a) =>
          a.startsWith('Prune worktree') ||
          a.startsWith('Delete local branch') ||
          a.startsWith('Delete remote branch'),
    ) ||
    r.executedActions.any(
      (a) =>
          a.description.contains('worktree') ||
          a.description.contains('branch'),
    );

String _formatActionableMarkdownRow(PrCleanResult r, {required bool applied}) {
  final pr = r.pr;
  final repoLink = '[**${pr.repository}**](${pr.repoUrl})';
  final prLink = '[#${pr.number}](${pr.url})';
  final localDir = r.localRepo != null
      ? '[`${r.localRepo!.repoPath}`](file://${r.localRepo!.repoPath})'
      : '_Not cloned_';

  String statusDetail;
  if (applied) {
    statusDetail = r.executedActions
        .map((a) => '${a.success ? "✅" : "❌"} ${a.description}')
        .join('<br>');
  } else {
    statusDetail = r.plannedActions.map((a) => '• $a').join('<br>');
  }

  return '| $repoLink | $prLink | $localDir | $statusDetail |';
}

String _formatNoOpClusterMarkdownRow(
  List<PrCleanResult> list, {
  required bool applied,
}) {
  final first = list.first;
  final repoLink = '[**${first.pr.repository}**](${first.pr.repoUrl})';
  final prLinks = list.map((r) => '[#${r.pr.number}](${r.pr.url})').join(', ');
  final prLabel = list.length == 1
      ? '[#${first.pr.number}](${first.pr.url})'
      : '${list.length} PRs: $prLinks';

  final localDir = first.localRepo != null
      ? '[`${first.localRepo!.repoPath}`](file://${first.localRepo!.repoPath})'
      : '_Not cloned_';

  String statusDetail;
  if (first.localRepo == null) {
    statusDetail = '_Not cloned locally_';
  } else if (applied) {
    statusDetail = '✅ Up to date (no local branches)';
  } else {
    final hasPendingSync = list.any(
      (r) => r.plannedActions.any((a) => a.startsWith('Sync ')),
    );
    if (hasPendingSync) {
      statusDetail = '• Sync `main` to `origin/main` (no local branches)';
    } else {
      statusDetail = '✅ Up to date (no local branches)';
    }
  }

  return '| $repoLink | $prLabel | $localDir | $statusDetail |';
}

/// Formats output for terminal viewing.
void printTerminalReport(
  List<PrCleanResult> results, {
  required bool applied,
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) {
  final modeStr = applied
      ? green.wrap('🚀 Applied Cleanup')!
      : cyan.wrap('🔍 Preview Mode (Dry Run)')!;
  print('${styleBold.wrap("Landed PR Cleanup")} [$modeStr]\n');

  _printPrCleanResults(
    results,
    applied: applied,
    hasTrailingSection: unlinkedWorktrees.isNotEmpty,
  );
  _printUnlinkedWorktrees(unlinkedWorktrees);
}

void _printPrCleanResults(
  List<PrCleanResult> results, {
  required bool applied,
  required bool hasTrailingSection,
}) {
  if (results.isEmpty) {
    print(styleDim.wrap('No recently landed pull requests found.')!);
    if (hasTrailingSection) {
      print('');
    }
    return;
  }

  for (final r in results) {
    _printTerminalPrHeader(r);
    if (applied) {
      _printExecutedActions(r.executedActions);
    } else {
      _printPlannedActions(r.plannedActions, r.status);
    }
    print('');
  }
}

void _printUnlinkedWorktrees(List<UnlinkedWorktree> unlinkedWorktrees) {
  if (unlinkedWorktrees.isEmpty) return;

  print('${styleBold.wrap("Worktrees with No Associated PR:")}\n');
  for (final u in unlinkedWorktrees) {
    final folder = p.basename(u.worktreePath);
    final ahead = u.commitsAhead != null ? '${u.commitsAhead}' : 'unknown';
    final date = u.lastCommitDate ?? 'unknown';
    final subject =
        u.lastCommitSubject != null && u.lastCommitSubject!.isNotEmpty
        ? ' - "${u.lastCommitSubject}"'
        : '';
    print('  ${styleBold.wrap(folder)} (${u.repository})');
    print('    Branch:        ${u.branch}');
    print('    Path:          ${u.worktreePath}');
    print('    Commits Ahead: $ahead');
    print('    Last Commit:   $date$subject');
    print('');
  }
}

void _printTerminalPrHeader(PrCleanResult r) {
  final pr = r.pr;
  print('${styleBold.wrap("${pr.repository} #${pr.number}")}: ${pr.title}');
  print('  URL:    ${pr.url}');
  print('  Branch: ${pr.headRefName} -> ${pr.baseRefName}');
  if (r.localRepo != null) {
    print('  Local:  ${r.localRepo!.repoPath}');
  }
}

void _printExecutedActions(List<CleanAction> actions) {
  for (final act in actions) {
    final icon = act.success ? green.wrap('✅') : red.wrap('❌');
    print('  $icon ${act.description}');
    if (act.error != null) {
      print('     ${red.wrap("Error: ${act.error}")}');
    }
  }
}

void _printPlannedActions(List<String> plannedActions, String status) {
  if (plannedActions.isEmpty) {
    final statusColor = status == 'Not cloned locally'
        ? styleDim
        : status.contains('Failure')
        ? red
        : yellow;
    print('  Status: ${statusColor.wrap(status)}');
    return;
  }

  print('  Planned Actions:');
  for (final plan in plannedActions) {
    print('    • $plan');
  }
}

/// Formats output as machine-readable JSON.
Map<String, dynamic> formatJsonReport(
  List<PrCleanResult> results, {
  required bool applied,
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
}) => {
  'applied': applied,
  'total': results.length,
  'results': results
      .map(
        (r) => {
          'pr': {
            'number': r.pr.number,
            'title': r.pr.title,
            'url': r.pr.url,
            'repository': r.pr.repository,
            'headRefName': r.pr.headRefName,
            'baseRefName': r.pr.baseRefName,
            'mergedAt': r.pr.mergedAt?.toIso8601String(),
            'headRefExists': r.pr.headRefExists,
            'headRepository': r.pr.headRepository,
          },
          'localRepo': r.localRepo != null
              ? {
                  'repoName': r.localRepo!.repoName,
                  'repoPath': r.localRepo!.repoPath,
                  'currentBranch': r.localRepo!.currentBranch,
                }
              : null,
          'status': r.status,
          'plannedActions': r.plannedActions,
          'executedActions': r.executedActions
              .map(
                (a) => {
                  'description': a.description,
                  'success': a.success,
                  'error': a.error,
                },
              )
              .toList(),
        },
      )
      .toList(),
  'unlinkedWorktrees': [
    for (final u in unlinkedWorktrees)
      {
        'repository': u.repository,
        'worktreePath': u.worktreePath,
        'branch': u.branch,
        'sha': u.sha,
        'commitsAhead': u.commitsAhead,
        'lastCommitDate': u.lastCommitDate,
        'lastCommitSubject': u.lastCommitSubject,
      },
  ],
};
