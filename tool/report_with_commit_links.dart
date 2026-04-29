import 'dart:io';

void main() async {
  final logFile = File(
    '/Users/kevmoo/.gemini/jetski/brain/3ba74618-7463-4596-9ef2-1a10ebedc0cc/.system_generated/tasks/task-132.log',
  );
  if (!await logFile.exists()) {
    print('Log file not found');
    return;
  }

  final lines = await logFile.readAsLines();

  final prToCommit = <String, String>{};
  String? currentPr;

  // First pass: build PR -> Commit map
  for (final line in lines) {
    if (line.startsWith('Looking for commit for PR #')) {
      currentPr = line.substring(27).trim();
    } else if (line.startsWith('  Found commit: ') && currentPr != null) {
      final commit = line.substring(16).trim();
      prToCommit[currentPr] = commit;
      currentPr = null;
    }
  }

  print('Built map with ${prToCommit.length} PRs.');

  final webBullets = <String>{};
  bool inMatch = false;
  StringBuffer commentBody = StringBuffer();

  // Second pass: extract matches and associate commits
  for (final line in lines) {
    if (line.startsWith('--- MATCH ---')) {
      if (inMatch) {
        processComment(commentBody.toString(), prToCommit, webBullets);
      }
      inMatch = true;
      commentBody.clear();
    } else if (inMatch) {
      if (line.startsWith('Comment: ')) {
        commentBody.writeln(line.substring(9));
      } else if (line.startsWith('Issue: ') ||
          line.startsWith('Author: ') ||
          line.startsWith('Commit: ')) {
        // Skip these
      } else if (line.startsWith('Checking commit: ') ||
          line.startsWith('Looking for commit ')) {
        processComment(commentBody.toString(), prToCommit, webBullets);
        inMatch = false;
      } else {
        commentBody.writeln(line);
      }
    }
  }

  if (inMatch) {
    processComment(commentBody.toString(), prToCommit, webBullets);
  }

  final reportFile = File(
    '/Users/kevmoo/github/kevmoo/scripts/notable_commits_report.md',
  ); // Overwrite
  final sink = reportFile.openWrite();

  sink.writeln('# Notable Commits Report (Web Only with Commits)');
  sink.writeln(
    'Filtered by: After Flutter 3.32, Before 2026 cutoff, Line contains "web".',
  );
  sink.writeln();

  for (final bullet in webBullets) {
    sink.writeln(bullet);
  }

  await sink.close();
  print('Generated report with ${webBullets.length} bullets.');
  print('Overwrote ${reportFile.path}');
}

void processComment(
  String body,
  Map<String, String> prToCommit,
  Set<String> results,
) {
  final lines = body.split('\n');
  final prRegex = RegExp(r'\[#(\d+)\]');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('*') && line.toLowerCase().contains('web')) {
      String? pr;
      // Look at the next line for PR number (often in <sub>[#PR]...</sub>)
      if (i + 1 < lines.length) {
        final nextLine = lines[i + 1].trim();
        final match = prRegex.firstMatch(nextLine);
        if (match != null) {
          pr = match.group(1)!;
        }
      }

      // If not found on next line, look in the current line
      if (pr == null) {
        final match = prRegex.firstMatch(line);
        if (match != null) {
          pr = match.group(1)!;
        }
      }

      if (pr != null) {
        final commit = prToCommit[pr];
        if (commit != null) {
          final commitLink =
              ' (Commit: [$commit](https://github.com/flutter/flutter/commit/$commit))';
          results.add('$line$commitLink');
        } else {
          results.add(line);
        }
      } else {
        results.add(line);
      }
    }
  }
}
