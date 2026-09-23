import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/kscripts_runner.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<({int exitCode, List<String> lines})> _captureCli(
  List<String> args, {
  String? invokedAsEnv,
  String? executablePath,
}) async {
  final lines = <String>[];
  final code = await runZoned(
    () => wrappedForTesting(
      () => runKScriptsCli(
        args,
        invokedAsEnv: invokedAsEnv,
        executablePath: executablePath,
      ),
    ),
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

    test('KSCRIPTS_AS naming a known subcommand dispatches to it', () async {
      final result = await _captureCli(['--help'], invokedAsEnv: 'gh-view');
      check(result.exitCode).equals(0);
      check(result.lines.first).contains('active pull requests');
    });

    test(
      'KSCRIPTS_AS naming an unknown subcommand reports a stale binary',
      () async {
        final result = await _captureCli([
          '--check',
        ], invokedAsEnv: 'relay-whoami-from-the-future');
        check(result.exitCode).equals(ExitCode.config.code);
        check(result.lines.join('\n'))
          ..contains('invoked as "relay-whoami-from-the-future"')
          ..contains('newer than the installed binary')
          ..contains("dart install 'kevmoo_scripts@{git:")
          ..not((it) => it.contains('Usage: kscripts'));
      },
    );

    test(
      'a direct symlink to an unknown name also reports a stale binary',
      () async {
        final result = await _captureCli(
          ['--check'],
          invokedAsEnv: '',
          executablePath: '/usr/local/bin/relay-whoami-from-the-future',
        );
        check(result.exitCode).equals(ExitCode.config.code);
        check(result.lines.join('\n'))
          ..contains('invoked as "relay-whoami-from-the-future"')
          ..contains('upkeep update dart_install');
      },
    );

    test(
      'empty KSCRIPTS_AS is unset, not a name; argv[0] still dispatches',
      () async {
        final result = await _captureCli(
          ['--help'],
          invokedAsEnv: '',
          executablePath: '/usr/local/bin/gh-view',
        );
        check(result.exitCode).equals(0);
        check(result.lines.first).contains('active pull requests');
      },
    );

    test('the Dart VM executable names never count as an invoked name', () {
      for (final exe in ['/usr/bin/dart', '/opt/dart-sdk/bin/dartaotruntime']) {
        check(resolveInvokedSubcommand(invokedAsEnv: '', executablePath: exe))
            .isNull();
      }
      check(
        resolveInvokedSubcommand(
          invokedAsEnv: '',
          executablePath: '/x/kscripts',
        ),
      ).isNull();
    });

    test('resolveEffectiveKScriptsArgs handles multicall env and argv[0]', () {
      check(
        resolveEffectiveKScriptsArgs(
          ['--help'],
          invokedAsEnv: 'gh-clean',
          executablePath: '/usr/local/bin/kscripts',
        ),
      ).deepEquals(['gh-clean', '--help']);

      check(
        resolveEffectiveKScriptsArgs([
          '--markdown',
        ], executablePath: '/usr/local/bin/gh-view'),
      ).deepEquals(['gh-view', '--markdown']);

      check(
        resolveEffectiveKScriptsArgs(
          ['gh-view', '--help'],
          invokedAsEnv: 'kscripts',
          executablePath: '/usr/local/bin/kscripts',
        ),
      ).deepEquals(['gh-view', '--help']);
    });

    test(
      'checkKScriptsStaleness supports KSCRIPTS_REPO_DIR and bundle fallback',
      () {
        final tempDir = Directory.systemTemp.createTempSync('kscripts_test_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final bundleBinDir = Directory(
          p.join(tempDir.path, 'local', 'bundle', 'bin'),
        )..createSync(recursive: true);
        final exeFile = File(p.join(bundleBinDir.path, 'kscripts'))
          ..writeAsStringSync('binary');

        // 1. Neither KSCRIPTS_REPO_DIR nor pubspec.lock exists -> silent.
        final unresolvedMessages = <String>[];
        checkKScriptsStaleness(
          repoDirEnv: '',
          executableFile: exeFile,
          onStderr: unresolvedMessages.add,
        );
        check(unresolvedMessages).isEmpty();

        // 2. Repo exists with older main ref -> emits nothing.
        final repoDir = Directory(p.join(tempDir.path, 'scripts.dart'));
        final now = DateTime.now();
        final mainRef =
            File(p.join(repoDir.path, '.git', 'refs', 'heads', 'main'))
              ..createSync(recursive: true)
              ..writeAsStringSync('abc1234\n')
              ..setLastModifiedSync(now.subtract(const Duration(minutes: 5)));
        exeFile.setLastModifiedSync(now);

        final freshMessages = <String>[];
        checkKScriptsStaleness(
          repoDirEnv: repoDir.path,
          executableFile: exeFile,
          onStderr: freshMessages.add,
        );
        check(freshMessages).isEmpty();

        // 3. Repo main ref is newer than binary -> emits warning.
        mainRef.setLastModifiedSync(now.add(const Duration(minutes: 5)));
        final staleMessages = <String>[];
        checkKScriptsStaleness(
          repoDirEnv: repoDir.path,
          executableFile: exeFile,
          onStderr: staleMessages.add,
        );
        check(staleMessages.single)
          ..contains('kscripts binary is older than')
          ..contains('upkeep update dart_install');

        // 4. Fallback to ../../pubspec.lock when KSCRIPTS_REPO_DIR is unset.
        File(p.join(tempDir.path, 'local', 'pubspec.lock'))
            .writeAsStringSync('''
packages:
  kevmoo_scripts:
    dependency: "direct main"
    description:
      path: "${repoDir.path}"
      relative: false
    source: path
    version: "0.1.0"
''');
        final fallbackMessages = <String>[];
        checkKScriptsStaleness(
          repoDirEnv: '',
          executableFile: exeFile,
          onStderr: fallbackMessages.add,
        );
        check(fallbackMessages.single)
            .contains('kscripts binary is older than ${repoDir.path}');

        // 5. A `git` install records `path: "."` (a repo-internal subdir, not
        // a checkout) and must not be resolved against the CWD.
        File(p.join(tempDir.path, 'local', 'pubspec.lock'))
            .writeAsStringSync('''
packages:
  kevmoo_scripts:
    dependency: "direct main"
    description:
      path: "."
      ref: HEAD
      resolved-ref: "2e7c03eb4af9f66bb151cee2bb498f6a6c39731c"
      url: "https://github.com/kevmoo/scripts.dart.git"
    source: git
    version: "0.0.0"
''');
        // Run from inside an unrelated repo whose `main` ref is newer than the
        // binary: resolving `.` against the CWD would emit a bogus warning.
        final cwdRepo = Directory(p.join(tempDir.path, 'unrelated'))
          ..createSync();
        File(p.join(cwdRepo.path, '.git', 'refs', 'heads', 'main'))
          ..createSync(recursive: true)
          ..writeAsStringSync('def5678\n')
          ..setLastModifiedSync(now.add(const Duration(minutes: 5)));

        final gitInstallMessages = <String>[];
        final priorCwd = Directory.current;
        Directory.current = cwdRepo;
        try {
          checkKScriptsStaleness(
            repoDirEnv: '',
            executableFile: exeFile,
            onStderr: gitInstallMessages.add,
          );
        } finally {
          Directory.current = priorCwd;
        }
        check(gitInstallMessages).isEmpty();
      },
    );
  });
}
