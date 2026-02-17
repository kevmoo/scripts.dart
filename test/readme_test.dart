import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('README table is up-to-date', () async {
    final readmeFile = File('README.md');
    final readmeContent = readmeFile.readAsStringSync();

    final pubspecFile = File('pubspec.yaml');
    final pubspecContent = pubspecFile.readAsStringSync();
    final pubspec = loadYaml(pubspecContent) as YamlMap;
    final executables = pubspec['executables'] as YamlMap;

    // Look for lines that contain `| \`bin/`
    final tableLines = readmeContent
        .split('\n')
        .where((line) => line.contains('| `bin/') && line.endsWith('|'))
        .toList();

    expect(tableLines, isNotEmpty, reason: 'Should find table rows in README');

    // Make sure every item in `executables` is in the table
    final mappedExecutables = <String, String>{};
    for (var entry in executables.entries) {
      final key = entry.key as String;
      final value = (entry.value as String?) ?? key;
      mappedExecutables[key] = value;
    }

    expect(
      tableLines,
      hasLength(mappedExecutables.length),
      reason: 'Table should have one row for each executable',
    );

    for (final line in tableLines) {
      final columns = line.split('|').map((e) => e.trim()).toList();
      // Line: | `git-goma` | `bin/git_clean.dart` | Clean up... |
      // columns: ['', '`git-goma`', '`bin/git_clean.dart`', 'Clean up...', '']
      expect(columns.length, 5);

      final exeCol = columns[1].replaceAll('`', '');
      final binCol = columns[2].replaceAll('`', '');
      final helpCol = columns[3];

      expect(
        binCol,
        startsWith('bin/'),
        reason: 'Column 1 should be a bin/ script',
      );
      expect(binCol, endsWith('.dart'), reason: 'Column 1 should end in .dart');

      final binName = p.basenameWithoutExtension(binCol);

      // Verify executable name matches what's in pubspec.yaml
      expect(
        mappedExecutables.containsKey(exeCol),
        isTrue,
        reason: 'Executable \$exeCol is not in pubspec.yaml',
      );
      expect(
        mappedExecutables[exeCol],
        binName,
        reason: 'pubspec executable \$exeCol should point to \$binName',
      );

      // Verify the help text matches running the command
      final result = await Process.run('dart', [binCol, '--help']);
      expect(
        result.exitCode,
        0,
        reason:
            'Running \$binCol --help should exit 0. Stderr: \${result.stderr}',
      );

      final helpLines = (result.stdout as String).trim().split('\n');
      expect(
        helpLines,
        isNotEmpty,
        reason: 'Help output for \$binCol should not be empty',
      );

      final description = helpLines.first.trim();
      expect(
        helpCol,
        description,
        reason:
            'README description for \$exeCol does not match '
            '`--help` output of \$binCol',
      );
    }
  });
}
