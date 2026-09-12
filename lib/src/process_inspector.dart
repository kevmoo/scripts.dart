import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart_clean.dart';
import 'process_utils.dart';
import 'witr_types.dart';

/// Process metadata extracted via process introspection.
class ProcessInfo({
  required final int pid,
  final int? ppid,
  required final String cmdline,
  required final String name,
  final List<String> env = const [],
  final String? cwd,
});

/// Abstract interface for process inspection across operating systems.
abstract interface class ProcessInspector {
  /// Inspects a process by [pid], returning its metadata or null if
  /// unavailable.
  Future<ProcessInfo?> inspect(int pid);

  /// Returns the process ancestry chain starting from the root down to [pid].
  Future<List<({int pid, String command})>> ancestry(int pid);

  /// Determines whether the given parent PID is a process reaper.
  Future<bool> isReaper(int ppid);

  /// Display name of the system reaper (e.g. "launchd" or "systemd").
  String get reaperName;

  /// Returns the default inspector for the current platform.
  static ProcessInspector platform() {
    if (Platform.isLinux) {
      return ProcFsProcessInspector();
    } else if (Platform.isMacOS) {
      return WitrProcessInspector();
    } else {
      throw DartCleanException(
        'dart-clean is currently only supported on macOS and Linux.',
      );
    }
  }
}

/// Linux process inspector reading directly from `/proc`.
class ProcFsProcessInspector({final String procPath = '/proc'})
    implements ProcessInspector {
  @override
  String get reaperName => 'systemd';

  @override
  Future<ProcessInfo?> inspect(int pid) async {
    final pidDir = Directory('$procPath/$pid');
    if (!await pidDir.exists()) return null;

    final statContent = await _readProcString('$procPath/$pid/stat');
    if (statContent == null) return null;

    final (ppid, commFromStat) = _parseStat(statContent);

    final commFile = await _readProcString('$procPath/$pid/comm');
    final name = (commFile != null && commFile.isNotEmpty)
        ? commFile
        : (commFromStat ?? '<unknown>');

    final cmdline = await _readProcCmdline('$procPath/$pid/cmdline', name);
    final env = await _readProcEnviron('$procPath/$pid/environ');
    final cwd = await _readProcCwd('$procPath/$pid/cwd');

    return ProcessInfo(
      pid: pid,
      ppid: ppid,
      cmdline: cmdline,
      name: name,
      env: env,
      cwd: cwd,
    );
  }

  @override
  Future<List<({int pid, String command})>> ancestry(int pid) async {
    final chain = <({int pid, String command})>[];
    final visited = <int>{};
    var currentPid = pid;

    while (currentPid > 1 && visited.add(currentPid)) {
      final info = await inspect(currentPid);
      if (info == null) break;
      chain.add((pid: currentPid, command: info.cmdline));
      final nextPid = info.ppid;
      if (nextPid == null || nextPid <= 0 || nextPid == currentPid) break;
      currentPid = nextPid;
    }

    if (currentPid >= 1 && !visited.contains(currentPid)) {
      final topInfo = await inspect(currentPid);
      if (topInfo != null) {
        chain.add((pid: currentPid, command: topInfo.cmdline));
      }
    }

    return chain.reversed.toList();
  }

  @override
  Future<bool> isReaper(int ppid) async {
    if (ppid <= 1) return true;

    final parentInfo = await inspect(ppid);
    if (parentInfo == null) return true;

    if (parentInfo.name == 'systemd') {
      if (parentInfo.cmdline.contains('--user') || parentInfo.ppid == 1) {
        return true;
      }
    }

    return parentInfo.name == 'init' || parentInfo.name == 'launchd';
  }

  (int?, String?) _parseStat(String statContent) {
    final lastParen = statContent.lastIndexOf(')');
    if (lastParen == -1) return (null, null);

    final firstParen = statContent.indexOf('(');
    final comm = (firstParen != -1 && firstParen < lastParen)
        ? statContent.substring(firstParen + 1, lastParen)
        : null;

    final afterParen = statContent.substring(lastParen + 1).trim();
    final tokens = afterParen.split(RegExp(r'\s+'));
    if (tokens.length < 2) return (null, comm);

    return (int.tryParse(tokens[1]), comm);
  }

  Future<String?> _readProcString(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return (await file.readAsString()).trim();
    } catch (_) {
      return null;
    }
  }

  Future<String> _readProcCmdline(String path, String fallbackName) async {
    try {
      final file = File(path);
      if (!await file.exists()) return fallbackName;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return fallbackName;

      final parts = _splitNulSeparated(bytes);
      return parts.isNotEmpty ? parts.join(' ') : fallbackName;
    } catch (_) {
      return fallbackName;
    }
  }

  Future<List<String>> _readProcEnviron(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return const [];
      final bytes = await file.readAsBytes();
      return _splitNulSeparated(bytes);
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _readProcCwd(String path) async {
    try {
      final link = Link(path);
      if (!await link.exists()) return null;
      var target = await link.target();
      const deletedSuffix = ' (deleted)';
      if (target.endsWith(deletedSuffix)) {
        target = target.substring(0, target.length - deletedSuffix.length);
      }
      return target;
    } catch (_) {
      return null;
    }
  }

  List<String> _splitNulSeparated(Uint8List bytes) {
    if (bytes.isEmpty) return const [];
    return utf8
        .decode(bytes, allowMalformed: true)
        .split('\u0000')
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

/// macOS process inspector utilizing the `witr` command-line utility.
class WitrProcessInspector({final ProcessRunner runner = defaultProcessRunner})
    implements ProcessInspector {
  @override
  String get reaperName => 'launchd';

  @override
  Future<ProcessInfo?> inspect(int pid) async {
    try {
      final result = await runner('witr', ['--pid', '$pid', '--json']);
      final stdout = result.stdout as String;

      if (stdout.trim().isEmpty && result.exitCode != 0) {
        return null;
      }

      final data = WitrData.fromJson(
        jsonDecode(stdout) as Map<String, dynamic>,
      );

      final ppid = data.process.ppid;
      final parentName = ppid != null
          ? await getProcessName(ppid)
          : '<unknown>';
      final cwdEnv = data.process.env
          ?.where((String e) => e.startsWith('PWD='))
          .firstOrNull;
      final cwd = cwdEnv != null
          ? cwdEnv.substring(4)
          : await getProcessCwd(pid);

      return ProcessInfo(
        pid: pid,
        ppid: ppid,
        cmdline: data.process.cmdline,
        name: parentName,
        env: data.process.env ?? const [],
        cwd: cwd,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<({int pid, String command})>> ancestry(int pid) async {
    try {
      final treeResult = await runner('witr', [
        '--pid',
        '$pid',
        '--tree',
        '--json',
      ]);

      if (treeResult.exitCode != 0 && treeResult.stdout.toString().isEmpty) {
        return const [];
      }

      final treeOutput = treeResult.stdout as String;
      final treeData = jsonDecode(treeOutput) as Map<String, dynamic>;
      final ancestryJson = treeData['Ancestry'] as List<dynamic>? ?? const [];
      return ancestryJson.map((e) {
        final map = e as Map<String, dynamic>;
        return (pid: map['PID'] as int, command: map['Command'] as String);
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> isReaper(int ppid) async => ppid <= 1;
}
