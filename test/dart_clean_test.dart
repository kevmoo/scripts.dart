import 'package:kevmoo_scripts/src/dart_clean.dart';
import 'package:kevmoo_scripts/src/process_inspector.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('runDartClean with MockProcessInspector', () {
    test('identifies orphaned processes under systemd reaper', () async {
      final mockInspector = _MockProcessInspector(
        reaperPids: {1, 2217},
        processes: {
          1001: ProcessInfo(
            pid: 1001,
            ppid: 2217, // parented to systemd --user subreaper
            cmdline: 'dart test/stale_test.dart',
            name: 'dart',
          ),
          1002: ProcessInfo(
            pid: 1002,
            ppid: 5000, // parented to live shell
            cmdline: 'dart run bin/active.dart',
            name: 'dart',
          ),
        },
      );

      // Run dart-clean in list mode
      await runDartClean(
        DartCleanOptions(list: true),
        inspector: mockInspector,
      );
    });
  });
}

class _MockProcessInspector({
  required final Set<int> reaperPids,
  required final Map<int, ProcessInfo> processes,
}) implements ProcessInspector {
  @override
  String get reaperName => 'systemd';

  @override
  Future<ProcessInfo?> inspect(int pid) async => processes[pid];

  @override
  Future<List<({int pid, String command})>> ancestry(int pid) async {
    final chain = <({int pid, String command})>[];
    var current = processes[pid];
    while (current != null) {
      chain.add((pid: current.pid, command: current.cmdline));
      final nextPid = current.ppid;
      if (nextPid == null) break;
      current = processes[nextPid];
    }
    return chain.reversed.toList();
  }

  @override
  Future<bool> isReaper(int ppid) async => reaperPids.contains(ppid);
}
