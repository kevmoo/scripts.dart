import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/process_inspector.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('ProcFsProcessInspector', () {
    late String procRoot;

    setUp(() async {
      await d.dir('mock_proc').create();
      procRoot = p.join(d.sandbox, 'mock_proc');
    });

    Future<void> createMockProc({
      required int pid,
      required int ppid,
      required String comm,
      String? cmdline,
      String? environ,
      String? cwd,
      String state = 'S',
    }) async {
      final pidDir = p.join(procRoot, pid.toString());
      await Directory(pidDir).create(recursive: true);

      // /proc/<pid>/stat format: <pid> (<comm>) <state> <ppid> ...
      final statContent =
          '$pid ($comm) $state $ppid $pid $pid 0 -1 4194304 0 0 0 0 0 0 0 20 '
          '0 1 0';
      await File(p.join(pidDir, 'stat')).writeAsString(statContent);

      await File(p.join(pidDir, 'comm')).writeAsString('$comm\n');

      final cmdBytes = (cmdline != null)
          ? cmdline.split(' ').join('\u0000').codeUnits + [0]
          : <int>[];
      await File(p.join(pidDir, 'cmdline')).writeAsBytes(cmdBytes);

      final envBytes = (environ != null)
          ? environ.split('\n').join('\u0000').codeUnits + [0]
          : <int>[];
      await File(p.join(pidDir, 'environ')).writeAsBytes(envBytes);

      if (cwd != null) {
        final link = Link(p.join(pidDir, 'cwd'));
        await link.create(cwd);
      }
    }

    test('inspect reads process metadata correctly', () async {
      final cwdDir = p.join(d.sandbox, 'workspace');
      await Directory(cwdDir).create();

      await createMockProc(
        pid: 1234,
        ppid: 100,
        comm: 'dart',
        cmdline: 'dart test.dart --flag',
        environ: 'VSCODE_PID=999\nFOO=BAR',
        cwd: cwdDir,
      );

      final inspector = ProcFsProcessInspector(procPath: procRoot);
      final info = await inspector.inspect(1234);

      check(info).isNotNull();
      check(info!.pid).equals(1234);
      check(info.ppid).equals(100);
      check(info.name).equals('dart');
      check(info.cmdline).equals('dart test.dart --flag');
      check(info.env).contains('VSCODE_PID=999');
      check(info.env).contains('FOO=BAR');
      check(info.cwd).equals(cwdDir);
    });

    test('inspect parses comm containing spaces and parentheses', () async {
      await createMockProc(
        pid: 2345,
        ppid: 1,
        comm: 'my (custom) proc',
        cmdline: 'custom-app run',
      );

      final inspector = ProcFsProcessInspector(procPath: procRoot);
      final info = await inspector.inspect(2345);

      check(info).isNotNull();
      check(info!.pid).equals(2345);
      check(info.ppid).equals(1);
      check(info.name).equals('my (custom) proc');
      check(info.cmdline).equals('custom-app run');
    });

    test('inspect falls back to comm when cmdline is empty', () async {
      await createMockProc(
        pid: 3456,
        ppid: 1,
        comm: 'kworker',
        cmdline: '', // empty cmdline
      );

      final inspector = ProcFsProcessInspector(procPath: procRoot);
      final info = await inspector.inspect(3456);

      check(info).isNotNull();
      check(info!.cmdline).equals('kworker');
    });

    test('inspect strips (deleted) suffix from cwd', () async {
      final pidDir = p.join(procRoot, '4567');
      await Directory(pidDir).create(recursive: true);
      await File(p.join(pidDir, 'stat')).writeAsString('4567 (app) S 1 4567');
      await File(p.join(pidDir, 'comm')).writeAsString('app\n');
      await File(p.join(pidDir, 'cmdline')).writeAsString('app\u0000');

      // Link pointing to a deleted path with suffix
      final link = Link(p.join(pidDir, 'cwd'));
      await link.create('/path/to/old/dir (deleted)');

      final inspector = ProcFsProcessInspector(procPath: procRoot);
      final info = await inspector.inspect(4567);

      check(info).isNotNull();
      check(info!.cwd).equals('/path/to/old/dir');
    });

    test('inspect returns null for non-existent PID', () async {
      final inspector = ProcFsProcessInspector(procPath: procRoot);
      final info = await inspector.inspect(99999);
      check(info).isNull();
    });

    test('ancestry builds full process tree up to root', () async {
      // 1 (init) -> 2217 (systemd --user) -> 5000 (bash) -> 6000 (dart)
      await createMockProc(
        pid: 1,
        ppid: 0,
        comm: 'systemd',
        cmdline: '/sbin/init',
      );
      await createMockProc(
        pid: 2217,
        ppid: 1,
        comm: 'systemd',
        cmdline: '/usr/lib/systemd/systemd --user',
      );
      await createMockProc(
        pid: 5000,
        ppid: 2217,
        comm: 'bash',
        cmdline: '/bin/bash',
      );
      await createMockProc(
        pid: 6000,
        ppid: 5000,
        comm: 'dart',
        cmdline: 'dart run',
      );

      final inspector = ProcFsProcessInspector(procPath: procRoot);
      final chain = await inspector.ancestry(6000);

      check(chain.length).equals(4);
      check(chain[0].pid).equals(1);
      check(chain[0].command).equals('/sbin/init');
      check(chain[1].pid).equals(2217);
      check(chain[1].command).equals('/usr/lib/systemd/systemd --user');
      check(chain[2].pid).equals(5000);
      check(chain[2].command).equals('/bin/bash');
      check(chain[3].pid).equals(6000);
      check(chain[3].command).equals('dart run');
    });

    test('isReaper detects PID 1, systemd --user, and non-reapers', () async {
      // PID 1
      await createMockProc(
        pid: 1,
        ppid: 0,
        comm: 'systemd',
        cmdline: '/sbin/init',
      );
      // systemd --user subreaper
      await createMockProc(
        pid: 2217,
        ppid: 1,
        comm: 'systemd',
        cmdline: '/usr/lib/systemd/systemd --user',
      );
      // Regular process (bash)
      await createMockProc(
        pid: 5000,
        ppid: 2217,
        comm: 'bash',
        cmdline: '/bin/bash',
      );

      final inspector = ProcFsProcessInspector(procPath: procRoot);

      // PID 1 is always a reaper
      check(await inspector.isReaper(1)).isTrue();
      check(await inspector.isReaper(0)).isTrue();

      // systemd --user is a reaper
      check(await inspector.isReaper(2217)).isTrue();

      // bash is NOT a reaper
      check(await inspector.isReaper(5000)).isFalse();

      // Non-existent PID (dead parent) is treated as a reaper
      check(await inspector.isReaper(8888)).isTrue();
    });
  });
}
