import 'dart:async';

import 'package:git/git.dart';

extension TestGitDirExtensions on GitDir {
  /// Configures a standard test identity for the repository to prevent dirty
  /// working trees or commit author errors on CI/Windows.
  Future<void> configureTestIdentity() async {
    await runCommand(['config', 'user.email', 'test@test.com']);
    await runCommand(['config', 'user.name', 'Tester']);
    await runCommand(['config', 'core.autocrlf', 'false']);
  }
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
