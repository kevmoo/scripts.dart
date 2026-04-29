import 'dart:io';

const flutterRepo = '/Users/kevmoo/github/flutter';

void main() async {
  final file = File(
    '/Users/kevmoo/github/kevmoo/scripts/notable_commits_report.md',
  );
  if (!await file.exists()) {
    print('File not found');
    return;
  }

  final content = await file.readAsString();
  final sections = content.split('\n## Commit: ');

  final prunedSections = <String>[];
  prunedSections.add(sections[0]); // The header

  print('Total sections to check: ${sections.length - 1}');

  int kept = 0;
  int pruned = 0;

  for (var i = 1; i < sections.length; i++) {
    final section = sections[i];
    final lines = section.split('\n');
    if (lines.isEmpty) continue;

    final commit = lines[0].trim();

    if (await isWebRelated(commit)) {
      prunedSections.add('\n## Commit: $section');
      kept++;
    } else {
      pruned++;
    }
  }

  await file.writeAsString(prunedSections.join(''));
  print('Pruning complete. Kept $kept, pruned $pruned.');
  print('Overwrote ${file.path}');
}

Future<bool> isWebRelated(String commit) async {
  final result = await Process.run('git', [
    '-C',
    flutterRepo,
    'log',
    '-1',
    '--format=%s%b',
    commit,
  ]);

  if (result.exitCode == 0) {
    final msg = result.stdout as String;
    if (msg.toLowerCase().contains('web')) return true;
  }

  final filesResult = await Process.run('git', [
    '-C',
    flutterRepo,
    'diff-tree',
    '--no-commit-id',
    '--name-only',
    '-r',
    commit,
  ]);

  if (filesResult.exitCode == 0) {
    final files = filesResult.stdout as String;
    if (files.toLowerCase().contains('web')) return true;
  }

  return false;
}
