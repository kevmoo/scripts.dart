import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:io/ansi.dart';

import 'util.dart';

/// Function signature for running an asynchronous process.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

/// Function signature for running a synchronous process.
typedef SyncProcessRunner = ProcessResult Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

/// Default synchronous process runner.
ProcessResult defaultSyncProcessRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) =>
    Process.runSync(executable, arguments, workingDirectory: workingDirectory);

/// Default asynchronous process runner.
Future<ProcessResult> defaultProcessRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.run(executable, arguments, workingDirectory: workingDirectory);

Future<String> getProcessCmdline(int pid, {String procPath = '/proc'}) async {
  if (Platform.isLinux) {
    final procCmd = await _readProcCmdline(pid, procPath);
    if (procCmd != null) return procCmd;
  }

  try {
    final output = await runProcess('ps', [
      '-p',
      pid.toString(),
      '-o',
      'command=',
    ]);
    return output.trim();
  } on ProcessException {
    return '<unknown>';
  }
}

Future<String?> _readProcCmdline(int pid, String procPath) async {
  try {
    final cmdlineFile = File('$procPath/$pid/cmdline');
    if (await cmdlineFile.exists()) {
      final bytes = await cmdlineFile.readAsBytes();
      if (bytes.isNotEmpty) {
        final parts = utf8
            .decode(bytes, allowMalformed: true)
            .split('\u0000')
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) return parts.join(' ');
      }
    }
    final commFile = File('$procPath/$pid/comm');
    if (await commFile.exists()) {
      final comm = (await commFile.readAsString()).trim();
      if (comm.isNotEmpty) return comm;
    }
  } catch (_) {}
  return null;
}

Future<bool> isProcessRunning(int pid, {String procPath = '/proc'}) async {
  if (Platform.isLinux) {
    return Directory('$procPath/$pid').exists();
  }

  try {
    await runProcess('ps', ['-p', pid.toString(), '-o', 'pid=']);
    return true;
  } on ProcessException {
    return false;
  }
}

Future<String?> getProcessCwd(int pid, {String procPath = '/proc'}) async {
  if (Platform.isLinux) {
    try {
      final link = Link('$procPath/$pid/cwd');
      if (await link.exists()) {
        var target = await link.target();
        const deletedSuffix = ' (deleted)';
        if (target.endsWith(deletedSuffix)) {
          target = target.substring(0, target.length - deletedSuffix.length);
        }
        return target;
      }
    } catch (_) {}
  }

  try {
    final output = await runProcess('lsof', [
      '-a',
      '-p',
      pid.toString(),
      '-d',
      'cwd',
      '-Fn',
    ]);
    for (final line in LineSplitter.split(output)) {
      if (line.startsWith('n')) {
        final path = line.substring(1).trim();
        if (path.contains('(readlink:')) return null;
        return path;
      }
    }
    return null;
  } on ProcessException {
    return null;
  }
}

String abbreviatePath(String path) {
  final home = Platform.environment['HOME'];
  if (home != null && path.startsWith(home)) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

Future<String> getProcessName(int pid, {String procPath = '/proc'}) async {
  if (Platform.isLinux) {
    try {
      final commFile = File('$procPath/$pid/comm');
      if (await commFile.exists()) {
        final comm = (await commFile.readAsString()).trim();
        if (comm.isNotEmpty) return comm;
      }
    } catch (_) {}
  }

  try {
    final output = await runProcess('ps', [
      '-p',
      pid.toString(),
      '-o',
      'comm=',
    ]);
    return output.trim().split('/').last;
  } on ProcessException {
    return '<unknown>';
  }
}

Future<void> killPids(List<int> pids, {bool force = false}) async {
  final (:killedCount, :failedPids, :stillRunning) = await _initialKillPids(
    pids,
  );

  var totalKilled = killedCount;
  final finalFailedPids = List<int>.from(failedPids);

  if (stillRunning.isNotEmpty) {
    final (extraKilled, extraFailed) = await _forceKillRemaining(
      stillRunning,
      force: force,
    );
    totalKilled += extraKilled;
    finalFailedPids.addAll(extraFailed);
  }

  _printKillSummary(totalKilled, finalFailedPids.toSet().toList());
}

Future<({int killedCount, List<int> failedPids, List<int> stillRunning})>
_initialKillPids(List<int> pids) async {
  var killedCount = 0;
  final failedPids = <int>[];

  for (final p in pids) {
    print('Killing $p...');
    if (!Process.killPid(p)) {
      failedPids.add(p);
    }
  }

  if (pids.length > failedPids.length) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  final stillRunning = <int>[];
  for (final p in pids) {
    if (failedPids.contains(p)) continue;
    if (await isProcessRunning(p)) {
      stillRunning.add(p);
    } else {
      killedCount++;
    }
  }

  return (
    killedCount: killedCount,
    failedPids: failedPids,
    stillRunning: stillRunning,
  );
}

Future<(int, List<int>)> _forceKillRemaining(
  List<int> stillRunning, {
  required bool force,
}) async {
  var effectiveForce = force;
  if (!effectiveForce) {
    print('');
    print(red.wrap('${stillRunning.length} processes failed to terminate.'));
    stdout.write('Force kill (kill -9) remaining processes? (y/N) ');
    final response = stdin.readLineSync();
    effectiveForce = response?.toLowerCase() == 'y';
  }

  if (!effectiveForce) {
    return (0, List<int>.from(stillRunning));
  }

  for (final p in stillRunning) {
    print('Force killing $p...');
    Process.killPid(p, ProcessSignal.sigkill);
  }

  await Future<void>.delayed(const Duration(milliseconds: 500));

  var killed = 0;
  final failed = <int>[];
  for (final p in stillRunning) {
    if (await isProcessRunning(p)) {
      failed.add(p);
    } else {
      killed++;
    }
  }
  return (killed, failed);
}

void _printKillSummary(int killedCount, List<int> failedPids) {
  print('');
  if (killedCount > 0) {
    print(green.wrap('Successfully terminated $killedCount processes.'));
  }
  if (failedPids.isNotEmpty) {
    print(
      red.wrap(
        'Failed to terminate ${failedPids.length} processes: '
        '${failedPids.join(', ')}',
      ),
    );
  }
}

String formatCmdline(String cmdline) {
  if (cmdline == '<unknown>') return cmdline;

  final parts = cmdline.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return cmdline;

  final result = <String>[];

  // First part is the executable. Get the base name.
  final exePath = parts.first;
  final exeName = exePath.split('/').last;
  result.add(exeName);

  var addedArgs = 0;
  for (var i = 1; i < parts.length; i++) {
    final part = parts[i];
    if (part.isEmpty) continue;

    // Skip dashed flags
    if (part.startsWith('-')) continue;

    final baseName = part.split('/').last;
    if (part.endsWith('.dart') || part.endsWith('.snapshot')) {
      result.add(baseName);
      break; // Stop after the script
    }

    result.add(baseName);
    addedArgs++;

    if (addedArgs >= 3) break;
  }

  return result.join(' ');
}
