@TestOn('vm')
library;

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/shared/markdown_table.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeMarkdownCell', () {
    test('replaces pipes, strips CR, normalizes LF, and trims', () {
      check(sanitizeMarkdownCell('  Linux | Test\r\nLine 2\rLine 3  '))
          .equals('Linux / Test Line 2Line 3');
    });

    test('supports custom pipeReplacement', () {
      check(sanitizeMarkdownCell('Foo | Bar', pipeReplacement: r'\|'))
          .equals(r'Foo \| Bar');
    });
  });

  group('formatMarkdownCellLines', () {
    test('joins lines with <br> and sanitizes embedded pipes and newlines', () {
      final result = formatMarkdownCellLines([
        'Context: Foo | Bar\r\nSub-line',
        '',
        '[#126](https://example.com) Fix | issue',
      ]);
      check(result).equals(
        'Context: Foo / Bar<br>Sub-line<br><br>[#126](https://example.com) '
        'Fix / issue',
      );
    });

    test('replaces spaces with &nbsp; when nbsp is true', () {
      final result = formatMarkdownCellLines([
        'Review: ✅ Approved',
        'CI: 🔴 Failing',
      ], nbsp: true);
      check(result)
          .equals('Review:&nbsp;✅&nbsp;Approved<br>CI:&nbsp;🔴&nbsp;Failing');
    });
  });

  group('writeMarkdownTable & formatMarkdownTable', () {
    test('renders table with mdformat guards and alignments', () {
      final table = formatMarkdownTable(
        headers: const ['Metric', 'Count', 'Notes'],
        alignments: const [MdAlign.left, MdAlign.center, MdAlign.right],
        rows: const [
          ['Total | Open', '42', 'Line 1\nLine 2'],
        ],
      );

      check(table).equals('''
<!-- mdformat off(prevent table wrapping) -->
| Metric | Count | Notes |
| :--- | :---: | ---: |
| Total / Open | 42 | Line 1 Line 2 |
<!-- mdformat on -->''');
    });

    test('omits mdformat guards when mdformatGuard is false', () {
      final table = formatMarkdownTable(
        headers: const ['Col 1', 'Col 2'],
        rows: const [
          ['A', 'B'],
        ],
        mdformatGuard: false,
      );

      check(table).equals('''
| Col 1 | Col 2 |
| :--- | :--- |
| A | B |''');
    });
  });
}
