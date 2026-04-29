import 'dart:io';

void main() async {
  final file = File(
    '/Users/kevmoo/github/kevmoo/scripts/notable_commits_report.md',
  );
  if (!await file.exists()) {
    print('File not found');
    return;
  }

  final lines = await file.readAsLines();
  final webBullets = <String>{};

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('*') && trimmed.toLowerCase().contains('web')) {
      webBullets.add(trimmed);
    }
  }

  final reportFile = File(
    '/Users/kevmoo/github/kevmoo/scripts/notable_commits_report.md',
  ); // Overwrite
  final sink = reportFile.openWrite();

  sink.writeln('# Notable Commits Report (Web Only)');
  sink.writeln(
    'Filtered by: After Flutter 3.32, Before 2026 cutoff, Line contains "web".',
  );
  sink.writeln();

  for (final bullet in webBullets) {
    sink.writeln(bullet);
  }

  await sink.close();
  print('Extracted ${webBullets.length} web bullets.');
  print('Overwrote ${reportFile.path}');
}
