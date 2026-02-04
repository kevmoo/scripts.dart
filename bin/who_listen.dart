#!/usr/bin/env dart

import 'dart:convert';

import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/shared.dart';
import 'package:kevmoo_scripts/src/util.dart';
import 'package:kevmoo_scripts/src/witr_types.dart';

Future<void> main() async {
  try {
    final processes = await _getListeningProcesses();

    for (final process in processes.values) {
      final witrData = await _getWitrData(process.pid);

      final witrProcess = witrData.process;

      print('${witrProcess.pid}: ${witrProcess.command}');
      for (var ancester in witrData.ancestry) {
        if (ancester.command == 'launchd') {
          continue;
        }

        if (ancester.pid == witrProcess.pid) {
          continue;
        }

        print('  ${ancester.command}');
      }
    }
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}

Future<Map<int, _ListeningProcess>> _getListeningProcesses() async {
  final output = await runProcess('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN']);

  final processes = <int, _ListeningProcess>{};

  final lines = output.trim().split('\n');

  // Skip header line
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 9) continue;

    final pid = int.tryParse(parts[1]);
    if (pid == null) continue;

    // The endpoint description is in the 9th column (index 8) to the end
    final nameColumn = parts.sublist(8).join(' ').replaceAll(' (LISTEN)', '');

    final command = parts[0];
    final process = processes.putIfAbsent(
      pid,
      () => _ListeningProcess(pid, command),
    );
    process.endpoints.add(nameColumn);
  }

  return processes;
}

Future<WitrData> _getWitrData(int pid) async {
  final output = await runProcess('witr', ['--pid', pid.toString(), '--json']);

  try {
    return WitrData.fromJson(jsonDecode(output) as Map<String, dynamic>);
  } catch (e) {
    print('Failed to parse witr output for pid $pid:\n$output');
    rethrow;
  }
}

class _ListeningProcess {
  final int pid;
  final String name;
  final Set<String> endpoints = {};

  _ListeningProcess(this.pid, this.name);

  @override
  String toString() =>
      'ListeningProcess(pid: $pid, name: $name, '
      'endpoints: {${endpoints.join(', ')}})';
}
