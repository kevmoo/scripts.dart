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

Future<String> getProcessCmdline(int pid) async {
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

Future<bool> isProcessRunning(int pid) async {
  try {
    await runProcess('ps', ['-p', pid.toString(), '-o', 'pid=']);
    return true;
  } on ProcessException {
    return false;
  }
}

Future<String?> getProcessCwd(int pid) async {
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
        return line.substring(1).trim();
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

Future<String> getProcessName(int pid) async {
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
  var killedCount = 0;
  var failedPids = <int>[];

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

  if (stillRunning.isNotEmpty) {
    if (!force) {
      print('');
      print(red.wrap('${stillRunning.length} processes failed to terminate.'));
      stdout.write('Force kill (kill -9) remaining processes? (y/N) ');
      final response = stdin.readLineSync();
      force = response?.toLowerCase() == 'y';
    }

    if (force) {
      for (final p in stillRunning) {
        print('Force killing $p...');
        Process.killPid(p, ProcessSignal.sigkill);
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));

      for (final p in stillRunning) {
        if (await isProcessRunning(p)) {
          failedPids.add(p);
        } else {
          killedCount++;
        }
      }
    } else {
      failedPids.addAll(stillRunning);
    }
  }

  failedPids = failedPids.toSet().toList();

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
