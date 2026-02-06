import 'package:io/ansi.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:test/test.dart';

void main() {
  test('printError hits null assertion line in RuntimeState', () {
    expect(() => printError(''), prints(''));
  });
}
