import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:test/scaffolding.dart';

import 'test_helpers.dart';

void main() {
  test('printError hits null assertion line in RuntimeState', () async {
    final prints = await capturePrints(() => printError(''));
    check(prints).isEmpty();
  });
}
