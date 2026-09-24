import 'dart:convert';

import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;

import '../gh_clean.dart';
import '../shared/markdown_table.dart';

/// Renders and prints the `gh-clean` report according to [options].
void outputGhCleanReport(
  List<PrCleanResult> results,
  GhCleanOptions options, {
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
  List<ClosedUnmergedPr> closedUnmergedPrs = const [],
}) {
  if (options.json) {
    print(
      jsonEncode(
        formatJsonReport(
          results,
          applied: options.apply,
          unlinkedWorktrees: unlinkedWorktrees,
          closedUnmergedPrs: closedUnmergedPrs,
        ),
      ),
    );
  } else if (options.markdown) {
    print(
      formatMarkdownReport(
        results,
        applied: options.apply,
        unlinkedWorktrees: unlinkedWorktrees,
        closedUnmergedPrs: closedUnmergedPrs,
      ),
    );
  } else {
    printTerminalReport(
      results,
      applied: options.apply,
      unlinkedWorktrees: unlinkedWorktrees,
      closedUnmergedPrs: closedUnmergedPrs,
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
  List<ClosedUnmergedPr> closedUnmergedPrs = const [],
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
    final rows = _buildSortedReportRows(results, applied: applied);
    writeMarkdownTable(
      buffer,
      headers: const [
        'Repository',
        'PR(s)',
        'Local Directory',
        'Actions / Status',
      ],
      rows: rows.map((r) => r.cells),
    );
  }

  _appendClosedUnmergedMarkdownSection(buffer, closedUnmergedPrs);
  _appendUnlinkedWorktreesMarkdownSection(buffer, unlinkedWorktrees);
  return buffer.toString();
}

void _appendClosedUnmergedMarkdownSection(
  StringBuffer buffer,
  List<ClosedUnmergedPr> closedUnmergedPrs,
) {
  if (closedUnmergedPrs.isEmpty) return;

  buffer
    ..writeln()
    ..writeln('## Closed (Unmerged) Pull Requests')
    ..writeln();

  writeMarkdownTable(
    buffer,
    headers: const [
      'Repository',
      'Closed PR',
      'Branch / Worktree',
      'Verification Status',
    ],
    rows: closedUnmergedPrs.map((c) {
      final repoLink =
          '[**${c.repository}**](https://github.com/${c.repository})';
      final prLink = '[#${c.number}](${c.url})';
      final wtPart = c.worktreePath != null
          ? ' ([`${p.basename(c.worktreePath!)}`](file://${c.worktreePath}))'
          : '';
      final branchStr = '`${c.branch}`$wtPart';
      final statusStr = _formatClosedUnmergedStatus(c);
      return [repoLink, prLink, branchStr, statusStr];
    }),
  );
}

void _appendUnlinkedWorktreesMarkdownSection(
  StringBuffer buffer,
  List<UnlinkedWorktree> unlinkedWorktrees,
) {
  if (unlinkedWorktrees.isEmpty) return;

  buffer
    ..writeln()
    ..writeln('## Worktrees with No Associated PR')
    ..writeln();

  writeMarkdownTable(
    buffer,
    headers: const [
      'Repository',
      'Worktree',
      'Branch',
      'Commits Ahead',
      'Last Commit',
    ],
    alignments: const [
      MdAlign.left,
      MdAlign.left,
      MdAlign.left,
      MdAlign.center,
      MdAlign.left,
    ],
    rows: unlinkedWorktrees.map((u) {
      final repoLink =
          '[**${u.repository}**](https://github.com/${u.repository})';
      final wtLink =
          '[`${p.basename(u.worktreePath)}`](file://${u.worktreePath})';
      final branchStr = '`${u.branch}`';
      final aheadStr = u.commitsAhead != null ? '${u.commitsAhead}' : '?';
      final dateStr = u.lastCommitDate ?? '?';
      return [repoLink, wtLink, branchStr, aheadStr, dateStr];
    }),
  );
}

String _formatClosedUnmergedStatus(ClosedUnmergedPr c) {
  if (c.commitsAhead == 0) {
    return '✅ 0 commits ahead of trunk (superseded)';
  }
  if (c.shaMatchesPrHead) {
    final shortSha = c.headRefOid.length > 7
        ? c.headRefOid.substring(0, 7)
        : c.headRefOid;
    return '✅ Local SHA matches closed PR HEAD '
        '(`$shortSha` — archived on GitHub)';
  }
  final aheadLabel = c.commitsAhead != null
      ? '${c.commitsAhead} commit(s) ahead of trunk; '
      : '';
  return '⚠️ ${aheadLabel}Local SHA differs from closed PR HEAD';
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
        cells: _buildActionableMarkdownRowCells(r, applied: applied),
      ));
    }

    if (noOps.isNotEmpty) {
      rows.add((
        org: org,
        repo: repo,
        minPrNumber: noOps.first.pr.number,
        cells: _buildNoOpClusterMarkdownRowCells(noOps, applied: applied),
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
  List<String> cells,
});

bool _hasLocalBranchOrWorktreeAction(PrCleanResult r) =>
    r.plannedActions.any(
      (a) =>
          a.startsWith('Prune worktree') ||
          a.startsWith('Skip worktree') ||
          a.startsWith('Delete local branch') ||
          a.startsWith('Skip local branch') ||
          a.startsWith('Delete remote branch'),
    ) ||
    r.executedActions.any(
      (a) =>
          a.description.contains('worktree') ||
          a.description.contains('branch'),
    );

List<String> _buildActionableMarkdownRowCells(
  PrCleanResult r, {
  required bool applied,
}) {
  final pr = r.pr;
  final repoLink = '[**${pr.repository}**](${pr.repoUrl})';
  final prLink = '[#${pr.number}](${pr.url})';
  final localDir = r.localRepo != null
      ? '[`${r.localRepo!.repoPath}`](file://${r.localRepo!.repoPath})'
      : '_Not cloned_';

  final statusDetail = applied
      ? formatMarkdownCellLines(
          r.executedActions.map(
            (a) => '${a.success ? "✅" : "❌"} ${a.description}',
          ),
        )
      : formatMarkdownCellLines(r.plannedActions.map((a) => '• $a'));

  return [repoLink, prLink, localDir, statusDetail];
}

List<String> _buildNoOpClusterMarkdownRowCells(
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

  return [repoLink, prLabel, localDir, statusDetail];
}

/// Formats output for terminal viewing.
void printTerminalReport(
  List<PrCleanResult> results, {
  required bool applied,
  List<UnlinkedWorktree> unlinkedWorktrees = const [],
  List<ClosedUnmergedPr> closedUnmergedPrs = const [],
}) {
  final modeStr = applied
      ? green.wrap('🚀 Applied Cleanup')!
      : cyan.wrap('🔍 Preview Mode (Dry Run)')!;
  print('${styleBold.wrap("Landed PR Cleanup")} [$modeStr]\n');

  _printPrCleanResults(
    results,
    applied: applied,
    hasTrailingSection:
        closedUnmergedPrs.isNotEmpty || unlinkedWorktrees.isNotEmpty,
  );
  _printClosedUnmergedPrs(closedUnmergedPrs);
  _printUnlinkedWorktrees(unlinkedWorktrees);
}

void _printClosedUnmergedPrs(List<ClosedUnmergedPr> closedUnmergedPrs) {
  if (closedUnmergedPrs.isEmpty) return;

  print('${styleBold.wrap("Closed (Unmerged) Pull Requests:")}\n');
  for (final c in closedUnmergedPrs) {
    print('  ${styleBold.wrap("${c.repository} #${c.number}")}: ${c.title}');
    print('    URL:    ${c.url}');
    print('    Branch: ${c.branch}');
    if (c.worktreePath != null) {
      print('    Worktree: ${c.worktreePath}');
    }
    print('    Status: ${_formatClosedUnmergedStatus(c)}');
    print('');
  }
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
  List<ClosedUnmergedPr> closedUnmergedPrs = const [],
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
  'closedUnmergedPrs': [
    for (final c in closedUnmergedPrs)
      {
        'repository': c.repository,
        'number': c.number,
        'title': c.title,
        'url': c.url,
        'branch': c.branch,
        'headRefOid': c.headRefOid,
        'localSha': c.localSha,
        'worktreePath': c.worktreePath,
        'commitsAhead': c.commitsAhead,
        'shaMatchesPrHead': c.shaMatchesPrHead,
      },
  ],
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
