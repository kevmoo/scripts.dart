import 'dart:async';

import 'package:checks/checks.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/kscripts_runner.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:test/test.dart';

Future<({int exitCode, List<String> lines})> _captureCli(
  List<String> args,
) async {
  final lines = <String>[];
  final code = await runZoned(
    () => wrappedForTesting(() => runKScriptsCli(args)),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        lines.add(line);
      },
    ),
  );
  return (exitCode: code, lines: lines);
}

void main() {
  group('kscripts runner', () {
    test('prints usage when invoked with no arguments or --help', () async {
      for (final args in const <List<String>>[
        [],
        ['--help'],
        ['-h'],
        ['help'],
      ]) {
        final result = await _captureCli(args);
        check(result.exitCode).equals(0);
        check(result.lines.first).equals(kscriptsDescription);
        check(result.lines.join('\n'))
          ..contains('Usage: kscripts <subcommand> [arguments]')
          ..contains('gh-clean')
          ..contains('gh-view')
          ..contains('repo-align');
      }
    });

    test('dispatches help <subcommand> and <subcommand> --help', () async {
      for (final cmd in kscriptSubcommands) {
        final viaHelp = await _captureCli(['help', cmd.name]);
        check(
          because: 'kscripts help ${cmd.name} should exit 0',
          viaHelp.exitCode,
        ).equals(0);
        check(viaHelp.lines.first.trim()).equals(cmd.description);

        final viaFlag = await _captureCli([cmd.name, '--help']);
        check(
          because: 'kscripts ${cmd.name} --help should exit 0',
          viaFlag.exitCode,
        ).equals(0);
        check(viaFlag.lines.first.trim()).equals(cmd.description);
      }
    });

    test(
      'provides prescriptive hints for common mistakes and underscores',
      () async {
        final cleanResult = await _captureCli(['clean']);
        check(cleanResult.exitCode).equals(ExitCode.usage.code);
        check(cleanResult.lines.join('\n'))
            .contains('Did you mean "kscripts gh-clean"?');

        final underscoreResult = await _captureCli(['repo_align']);
        check(underscoreResult.exitCode).equals(ExitCode.usage.code);
        check(underscoreResult.lines.join('\n'))
            .contains('Did you mean "kscripts repo-align"?');

        final unknownHelp = await _captureCli(['help', 'align']);
        check(unknownHelp.exitCode).equals(ExitCode.usage.code);
        check(unknownHelp.lines.join('\n'))
            .contains('Did you mean "kscripts repo-align"?');
      },
    );

    test('fails with usage code on completely unknown subcommands', () async {
      final result = await _captureCli(['not-a-subcommand']);
      check(result.exitCode).equals(ExitCode.usage.code);
      check(result.lines.join('\n'))
        ..contains('Unknown subcommand "not-a-subcommand".')
        ..contains('Run "kscripts --help" to see available subcommands.');
    });
  });
}
