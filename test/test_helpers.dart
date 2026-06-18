import 'dart:async';

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
