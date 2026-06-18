// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:args/command_runner.dart';
import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/git_org_clean.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('git-org-clean options', () {
    test('missing org parameter throws UsageException', () {
      check(() => parseCleanArgs([]))
          .throws<UsageException>()
          .has((e) => e.message, 'message')
          .contains('Missing target GitHub organization!');
    });

    test('help flag does not require org parameter', () {
      final args = parseCleanArgs(['--help']);
      check(args.help).isTrue();
      check(args.org).isNull();
    });

    test('valid org parameter parses correctly', () {
      final args = parseCleanArgs(['--org', 'my-org']);
      check(args.help).isFalse();
      check(args.org).equals('my-org');
    });

    test('valid org parameter using short flag parses correctly', () {
      final args = parseCleanArgs(['-o', 'another-org']);
      check(args.help).isFalse();
      check(args.org).equals('another-org');
    });
  });
}
