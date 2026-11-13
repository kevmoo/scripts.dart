import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/process_utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('formatCmdline', () {
    test('formats a basic command and caps at 3 positional arguments', () {
      check(
        formatCmdline(
          '/usr/local/bin/dart run build_runner watch '
          '--delete-conflicting-outputs extra_arg fifth_arg',
        ),
      ).equals('dart run build_runner watch');
    });

    test('caps >3 positional arguments with interleaved flags', () {
      check(
        formatCmdline(
          '/opt/homebrew/Cellar/dart/3.7.0/libexec/bin/dartvm '
          '--verbose pub -C pkgs/foo global activate webdev 3.0.0',
        ),
      ).equals('dartvm pub foo global');
    });

    test('stops immediately after a .dart script argument', () {
      check(
        formatCmdline(
          '/opt/homebrew/bin/dart --observe=8080 bin/server.dart '
          '--port 8080 trailing_positional',
        ),
      ).equals('dart server.dart');
    });

    test('formats a nested test file execution', () {
      check(formatCmdline('dart --enable-asserts test/foo/bar_test.dart'))
          .equals('dart bar_test.dart');
    });

    test('stops immediately after a .snapshot script argument', () {
      check(
        formatCmdline(
          '/usr/lib/dart/bin/dart /cache/frontend_server.dart.snapshot '
          '--sdk-root /sdk trailing_arg',
        ),
      ).equals('dart frontend_server.dart.snapshot');
    });

    test('formats direct snapshot executable invocation', () {
      check(
        formatCmdline(
          '/b/s/w/ir/x/w/recipe_cleanup/recipe_cleanup.snapshot --dry-run',
        ),
      ).equals('recipe_cleanup.snapshot');
    });

    test('does not treat directory names ending in .dart/ as scripts', () {
      check(formatCmdline('dart analyze packages/scripts.dart/ lib'))
          .equals('dart analyze scripts.dart lib');
      check(
        formatCmdline('dart test packages/scripts.dart/test/run_test.dart arg'),
      ).equals('dart test run_test.dart');
    });

    test('formats trailing-slash directory arguments without empty tokens', () {
      check(formatCmdline('dart format lib/ test/'))
          .equals('dart format lib test');
    });

    test(
      'does not treat dotfiles or compound non-script extensions as scripts',
      () {
        check(formatCmdline('dart foo/.dart bar/.snapshot baz'))
            .equals('dart .dart .snapshot baz');
        check(formatCmdline('node build/web/main.dart.js arg2 arg3 arg4'))
            .equals('node main.dart.js arg2 arg3');
      },
    );

    test('skips dashed flags including flag=value.dart forms', () {
      check(
        formatCmdline(
          '/usr/bin/dart -Dfoo=bar.dart --packages=.dart_tool/package_config.json '
          'compile exe bin/main.dart ignored_after_script',
        ),
      ).equals('dart compile exe main.dart');
    });

    test('supports Windows path separators via pathContext', () {
      check(
        formatCmdline(
          r'C:\tools\dart-sdk\bin\dart.exe --enable-asserts '
          r'C:\repo\bin\server.dart --port 8080 extra',
          pathContext: p.windows,
        ),
      ).equals('dart.exe server.dart');
      check(
        formatCmdline(
          r'C:\tools\dart-sdk\bin\dart.exe analyze '
          r'C:\repo\packages\scripts.dart\ lib',
          pathContext: p.windows,
        ),
      ).equals('dart.exe analyze scripts.dart lib');
    });

    test('handles unknown and whitespace-only inputs', () {
      check(formatCmdline('<unknown>')).equals('<unknown>');
      check(formatCmdline(' dart   ')).equals('dart');
      check(formatCmdline('')).equals('');
      check(formatCmdline('   ')).equals('   ');
    });
  });

  group('getProcessName', () {
    test('extracts executable basename from nested POSIX ps output', () async {
      late String capturedExe;
      late List<String> capturedArgs;
      final name = await getProcessName(
        1234,
        processRunner: (exe, args, {workingDirectory}) async {
          capturedExe = exe;
          capturedArgs = args;
          return ProcessResult(1234, 0, '/opt/homebrew/bin/dart\n', '');
        },
      );

      check(capturedExe).equals('ps');
      check(capturedArgs).deepEquals(['-p', '1234', '-o', 'comm=']);
      check(name).equals('dart');
    });

    test('preserves bare process names without directory segments', () async {
      final name = await getProcessName(
        42,
        processRunner: (_, _, {workingDirectory}) async =>
            ProcessResult(42, 0, '  dartvm  \n', ''),
      );
      check(name).equals('dartvm');
    });

    test('extracts basename from Windows paths via pathContext', () async {
      final name = await getProcessName(
        77,
        pathContext: p.windows,
        processRunner: (_, _, {workingDirectory}) async =>
            ProcessResult(77, 0, 'C:\\tools\\dart-sdk\\bin\\dart.exe\r\n', ''),
      );
      check(name).equals('dart.exe');
    });

    test(
      'returns <unknown> on empty output, non-zero exit, or exception',
      () async {
        check(
          await getProcessName(
            1,
            processRunner: (_, _, {workingDirectory}) async =>
                ProcessResult(1, 0, '   \n', ''),
          ),
        ).equals('<unknown>');

        check(
          await getProcessName(
            2,
            processRunner: (_, _, {workingDirectory}) async =>
                ProcessResult(2, 1, '', 'No such process'),
          ),
        ).equals('<unknown>');

        check(
          await getProcessName(
            3,
            processRunner: (_, _, {workingDirectory}) async =>
                throw const ProcessException('ps', ['-p', '3', '-o', 'comm=']),
          ),
        ).equals('<unknown>');
      },
    );
  });

  group('isProcessRunning', () {
    test(
      'checks procPath/<pid> safely with or without trailing slash',
      () async {
        await d.dir('proc', [d.dir('4242')]).create();
        final procRoot = p.join(d.sandbox, 'proc');

        check(await isProcessRunning(4242, procPath: procRoot)).isTrue();
        check(await isProcessRunning(4242, procPath: '$procRoot/')).isTrue();
        check(await isProcessRunning(9999, procPath: procRoot)).isFalse();
      },
      skip: !Platform.isLinux ? 'Procfs check only applies on Linux' : null,
    );
  });
}
