@TestOn('vm')
library;

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/shared/markdown_table.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeMarkdownCell', () {
    test('replaces pipes, strips CR, normalizes LF to spaces, and trims', () {
      check(sanitizeMarkdownCell('  Linux | Test\r\nLine 2\rLine 3  '))
          .equals('Linux / Test Line 2Line 3');
    });

    test('converts newlines to <br> when newlinesToBr is true', () {
      check(
        sanitizeMarkdownCell(
          '  Context: Foo | Bar\r\nSub-line  ',
          newlinesToBr: true,
        ),
      ).equals('Context: Foo / Bar<br>Sub-line');
    });
  });
}
