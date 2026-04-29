import 'dart:io';

void main() async {
  final file = File(
    '/Users/kevmoo/github/kevmoo/scripts/notable_commits_report.md',
  );
  if (!await file.exists()) {
    print('File not found');
    return;
  }

  var content = await file.readAsString();

  // Remove the outer code blocks added by parse_matches.dart
  // Handle cases with or without extra newlines
  content = content.replaceAll(
    RegExp(r'- \*\*Comment\*\*:\s*\n+(\s*```\n)'),
    '- **Comment**:\n\n',
  );
  content = content.replaceAll(
    RegExp(r'\n```\s*\n+(\s*## Commit:)'),
    '\n\n## Commit:',
  );

  // Handle the end of the file
  content = content.replaceAll(RegExp(r'\n```\s*\n*$'), '\n');

  // Remove details tags
  content = content.replaceAll('<details>', '');
  content = content.replaceAll('</details>', '');
  content = content.replaceAll('<details >', '');

  await file.writeAsString(content);
  print('Cleaned up report file.');
}
