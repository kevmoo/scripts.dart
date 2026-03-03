import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:collection/collection.dart';
import 'package:io/ansi.dart';

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
      output.trim().split('\n').where((s) => s.isNotEmpty).map(int.parse);

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
        final vscodePidStr = data.process.env?.firstWhereOrNull(
          (e) => e.startsWith('VSCODE_PID='),
        );

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
    print('  [$p] ${data.process.cmdline}');
  }

  if (options.list) return;

  if (options.force) {
    await _killPids(orphanedPids);
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

Future<void> _killPids(List<int> pids) async {
  var killedCount = 0;
  final failedPids = <int>[];
  for (final p in pids) {
    print('Killing $p...');
    if (Process.killPid(p)) {
      killedCount++;
    } else {
      failedPids.add(p);
    }
  }
  print(green.wrap('Killed $killedCount processes.'));
  if (failedPids.isNotEmpty) {
    print(
      red.wrap(
        'Failed to kill ${failedPids.length} processes: '
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
