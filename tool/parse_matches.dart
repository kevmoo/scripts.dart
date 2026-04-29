import 'dart:io';

void main() async {
  final logFile = File(
    '/Users/kevmoo/.gemini/jetski/brain/3ba74618-7463-4596-9ef2-1a10ebedc0cc/.system_generated/tasks/task-132.log',
  );
  final lines = await logFile.readAsLines();

  final reportFile = File(
    '/Users/kevmoo/github/kevmoo/scripts/notable_commits_report.md',
  );
  final sink = reportFile.openWrite();

  sink.writeln('# Notable Commits Report');
  sink.writeln(
    'Filtered by: After Flutter 3.32, Before 2026 cutoff, Related to Web.',
  );
  sink.writeln();

  bool inMatch = false;
  String? issue;
  String? author;
  String? commit;
  StringBuffer comment = StringBuffer();

  for (final line in lines) {
    if (line.startsWith('--- MATCH ---')) {
      if (inMatch) {
        // Write previous match
        writeMatch(sink, issue, author, commit, comment.toString());
      }
      inMatch = true;
      issue = null;
      author = null;
      commit = null;
      comment.clear();
    } else if (inMatch) {
      if (line.startsWith('Issue: ')) {
        issue = line.substring(7);
      } else if (line.startsWith('Author: ')) {
        author = line.substring(8);
      } else if (line.startsWith('Commit: ')) {
        commit = line.substring(8);
      } else if (line.startsWith('Comment: ')) {
        comment.writeln(line.substring(9));
      } else if (line.startsWith('Checking commit: ') ||
          line.startsWith('Looking for commit ')) {
        // End of comment body, start of next lookup
        writeMatch(sink, issue, author, commit, comment.toString());
        inMatch = false;
      } else {
        comment.writeln(line);
      }
    }
  }

  if (inMatch) {
    writeMatch(sink, issue, author, commit, comment.toString());
  }

  await sink.close();
  print('Report generated at ${reportFile.path}');
}

void writeMatch(
  IOSink sink,
  String? issue,
  String? author,
  String? commit,
  String comment,
) {
  sink.writeln('## Commit: $commit');
  sink.writeln('- **Issue**: $issue');
  sink.writeln('- **Author**: $author');
  sink.writeln('- **Comment**:');
  sink.writeln('```');
  sink.writeln(comment.trim());
  sink.writeln('```');
  sink.writeln();
}
