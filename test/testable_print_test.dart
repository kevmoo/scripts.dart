import 'dart:async';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:test/scaffolding.dart';

void main() {
  test('printError hits null assertion line in RuntimeState', () async {
    final prints = await capturePrints(() => printError(''));
    check(prints).isEmpty();
  });
}

Future<List<String>> capturePrints(FutureOr<void> Function() action) async {
  final prints = <String>[];
  await runZoned(
    () async {
      await action();
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        prints.add(line);
      },
    ),
  );
  return prints;
}
