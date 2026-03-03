import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
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

  // Find all dart processes
  final pids = <int>{};
  for (final exe in ['dart', 'dartvm']) {
    try {
      final output = await runProcess('pgrep', [exe]);
      pids.addAll(output.trim().split('\n').map(int.parse));
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
    protectedPids.addAll(childrenOutput.trim().split('\n').map(int.parse));
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
    _killPids(orphanedPids);
  } else {
    print('');
    stdout.write('Kill all orphaned processes? (y/N) ');
    final response = stdin.readLineSync();
    if (response?.toLowerCase() == 'y') {
      _killPids(orphanedPids);
    } else {
      print('Skipping kill.');
    }
  }
}

void _killPids(List<int> pids) {
  for (final p in pids) {
    print('Killing $p...');
    Process.killPid(p);
  }
  print(green.wrap('Killed ${pids.length} processes.'));
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
