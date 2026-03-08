import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/ansi.dart';
import 'package:meta/meta.dart';

import 'util.dart';
import 'witr_types.dart';

part 'dart_clean.g.dart';

Future<void> runDartClean(DartCleanOptions options) async {
  if (!Platform.isMacOS) {
    throw DartCleanException(
      'dart-clean is currently only supported on macOS.',
    );
  }

  final currentPid = pid;

  Iterable<int> parsePgrepOutput(String output) =>
      LineSplitter.split(output).where((s) => s.isNotEmpty).map(int.parse);

  // Find all dart processes
  final pids = <int>{};
  for (final exe in ['dart', 'dartvm']) {
    try {
      final output = await runProcess('pgrep', [exe]);
      pids.addAll(parsePgrepOutput(output));
    } on ProcessException catch (e) {
      if (e.errorCode != 1) rethrow;
    }
  }

  // Get current process children so we don't kill them
  final protectedPids = {currentPid};
  try {
    final childrenOutput = await runProcess('pgrep', [
      '-P',
      currentPid.toString(),
    ]);
    protectedPids.addAll(parsePgrepOutput(childrenOutput));
  } on ProcessException catch (e) {
    if (e.errorCode != 1) rethrow;
  }

  final orphanedPids = <int>[];
  final orphanedDetails = <int, WitrData>{};

  print('Checking ${pids.length} processes...');

  for (final p in pids) {
    if (protectedPids.contains(p)) continue;

    try {
      final witrOutput = await runProcess('witr', [
        '--pid',
        p.toString(),
        '--json',
      ]);
      final data = WitrData.fromJson(
        jsonDecode(witrOutput) as Map<String, dynamic>,
      );

      if (data.source.type == 'launchd') {
        // Check if it's owned by a running VS Code instance
        final vscodePidStr = data.process.env
            ?.where((e) => e.startsWith('VSCODE_PID='))
            .firstOrNull;

        if (vscodePidStr != null) {
          final vscodePid = int.tryParse(vscodePidStr.split('=')[1]);
          if (vscodePid != null) {
            if (await _isProcessRunning(vscodePid)) {
              continue;
            }
          }
        }

        orphanedPids.add(p);
        orphanedDetails[p] = data;
      }
    } on ProcessException {
      // Process might have exited
      continue;
    } catch (e) {
      // Failed to parse witr output or something else
      stderr.writeln('Warning: failed to check PID $p: $e');
      continue;
    }
  }

  if (orphanedPids.isEmpty) {
    print(green.wrap('No orphaned Dart processes found.'));
    return;
  }

  print(yellow.wrap('Found ${orphanedPids.length} orphaned Dart processes:'));
  for (final p in orphanedPids) {
    final data = orphanedDetails[p]!;
    print('  [$p] ${formatCmdline(data.process.cmdline)}');
  }

  if (options.list) return;

  if (options.force) {
    await _killPids(orphanedPids, force: true);
  } else {
    print('');
    stdout.write('Kill all orphaned processes? (y/N) ');
    final response = stdin.readLineSync();
    if (response?.toLowerCase() == 'y') {
      await _killPids(orphanedPids);
    } else {
      print('Skipping kill.');
    }
  }
}

Future<bool> _isProcessRunning(int pid) async {
  try {
    await runProcess('ps', ['-p', pid.toString(), '-o', 'pid=']);
    return true;
  } on ProcessException {
    return false;
  }
}

Future<void> _killPids(List<int> pids, {bool force = false}) async {
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
    if (await _isProcessRunning(p)) {
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
        if (await _isProcessRunning(p)) {
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

@CliOptions()
class DartCleanOptions {
  @CliOption(abbr: 'f', help: 'Force kill without confirmation.')
  final bool force;

  @CliOption(abbr: 'l', help: 'Only list orphaned processes; do not kill.')
  final bool list;

  @CliOption(abbr: 'h', negatable: false, help: 'Print this usage information.')
  final bool help;

  DartCleanOptions({this.force = false, this.list = false, this.help = false});
}

String get dartCleanOptionsUsage => _$parserForDartCleanOptions.usage;

ArgParser get dartCleanOptionsParser => _$parserForDartCleanOptions;

class DartCleanException implements Exception {
  final String message;

  DartCleanException(this.message);

  @override
  String toString() => message;
}

@visibleForTesting
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
