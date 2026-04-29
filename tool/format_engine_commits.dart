import 'dart:io';

const flutterRepo = '/Users/kevmoo/github/flutter';
const targetCommit = 'ef44a7c3cef6fee67fbe29d4944632d8188d3ba7';
const startTag = '3.32.0';

void main() async {
  print('Fetching all engine commits...');

  final result = await Process.run('git', [
    '-C',
    flutterRepo,
    'log',
    '--date=short',
    '--format=@@@%s%nhttps://github.com/flutter/flutter/commit/%H%n%an%n%ad%n%b',
    '^$startTag',
    targetCommit,
    '--',
    'engine/src/flutter/lib/web_ui',
  ]);

  if (result.exitCode != 0) {
    print('Failed to get git log: ${result.stderr}');
    return;
  }

  final output = result.stdout as String;
  final blocks = output.split('@@@');

  final reportFile = File(
    '/Users/kevmoo/github/kevmoo/scripts/engine_commits_report.md',
  );
  final sink = reportFile.openWrite();

  sink.writeln('# Engine Commits Report (Filtered)');
  sink.writeln('Filtered by: engine/src/flutter/lib/web_ui');
  sink.writeln();

  int kept = 0;
  int filtered = 0;

  for (final block in blocks) {
    if (block.trim().isEmpty) continue;

    final lines = block.split('\n');
    final title = lines[0].trim();
    final link = lines[1].trim();
    final author = lines[2].trim();
    final date = lines[3].trim();

    final bodyLines = lines.sublist(4);
    final body = bodyLines.join('\n');

    // Apply filters
    final titleLower = title.toLowerCase();
    if (titleLower.startsWith('[web] roll') || titleLower.startsWith('roll ')) {
      filtered++;
      continue;
    }
    if (titleLower.contains('lint') ||
        titleLower.contains('unused parameter') ||
        titleLower.contains('formatting')) {
      filtered++;
      continue;
    }
    if (titleLower.startsWith('revert') || titleLower.contains('revert(')) {
      filtered++;
      continue;
    }

    // Truncate boilerplate
    var cleanBody = body;
    final checklistIndex = cleanBody.indexOf('## Pre-launch Checklist');
    if (checklistIndex != -1) {
      cleanBody = cleanBody.substring(0, checklistIndex);
    }
    final commentIndex = cleanBody.indexOf('<!--');
    if (commentIndex != -1) {
      cleanBody = cleanBody.substring(0, commentIndex);
    }

    sink.writeln('### $title');
    sink.writeln('- **Author**: $author');
    sink.writeln('- **Date**: $date');
    sink.writeln('- **Link**: $link');
    sink.writeln();
    sink.writeln(cleanBody.trim());
    sink.writeln();
    sink.writeln('---');
    sink.writeln();

    kept++;
  }

  await sink.close();
  print('Generated report with $kept commits (filtered $filtered).');
  print('Overwrote ${reportFile.path}');
}
