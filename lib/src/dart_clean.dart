import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/ansi.dart';
import 'process_utils.dart';
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
  final skipMessages = <SkipMessage>[];

  print('Checking ${pids.length} processes...');

  for (final p in pids) {
    if (protectedPids.contains(p)) {
      final cmdline = formatCmdline(await getProcessCmdline(p));
      final cwd = await getProcessCwd(p);
      skipMessages.add((
        pid: p,
        cmdline: cmdline,
        parentPid: null,
        parentName: null,
        cwd: cwd,
        reason: 'since it is a protected process (current script or child).',
      ));
      continue;
    }

    try {
      final result = await Process.run('witr', [
        '--pid',
        p.toString(),
        '--json',
      ]);

      final witrOutput = result.stdout as String;

      if (witrOutput.trim().isEmpty && result.exitCode != 0) {
        final cmdline = formatCmdline(await getProcessCmdline(p));
        final cwd = await getProcessCwd(p);
        skipMessages.add((
          pid: p,
          cmdline: cmdline,
          parentPid: null,
          parentName: null,
          cwd: cwd,
          reason:
              'since witr failed with exit code ${result.exitCode} '
              'and no output.',
        ));
        continue;
      }

      final data = WitrData.fromJson(
        jsonDecode(witrOutput) as Map<String, dynamic>,
      );

      final ppid = data.process.ppid;
      final parentName = ppid != null
          ? await getProcessName(ppid)
          : '<unknown>';

      if (ppid != 1) {
        final cwdEnv = data.process.env
            ?.where((String e) => e.startsWith('PWD='))
            .firstOrNull;
        final cwd = cwdEnv != null
            ? cwdEnv.substring(4)
            : await getProcessCwd(p);
        skipMessages.add((
          pid: p,
          cmdline: formatCmdline(data.process.cmdline),
          parentPid: ppid,
          parentName: parentName,
          cwd: cwd,
          reason: '',
        ));
        continue;
      }

      // Check if it's owned by a running VS Code instance
      final vscodePidStr = data.process.env
          ?.where((String e) => e.startsWith('VSCODE_PID='))
          .firstOrNull;

      if (vscodePidStr != null) {
        final vscodePid = int.tryParse(vscodePidStr.split('=')[1]);
        if (vscodePid != null) {
          if (await isProcessRunning(vscodePid)) {
            final cwdEnv = data.process.env
                ?.where((String e) => e.startsWith('PWD='))
                .firstOrNull;
            final cwd = cwdEnv != null
                ? cwdEnv.substring(4)
                : await getProcessCwd(p);
            skipMessages.add((
              pid: p,
              cmdline: formatCmdline(data.process.cmdline),
              parentPid: null,
              parentName: null,
              cwd: cwd,
              reason:
                  'parent is launchd, but since VS Code '
                  '(PID $vscodePid) is running.',
            ));
            continue;
          }
        }
      }

      orphanedPids.add(p);
      orphanedDetails[p] = data;
    } on ProcessException {
      final cmdline = formatCmdline(await getProcessCmdline(p));
      final cwd = await getProcessCwd(p);
      skipMessages.add((
        pid: p,
        cmdline: cmdline,
        parentPid: null,
        parentName: null,
        cwd: cwd,
        reason: 'since process likely exited.',
      ));
      continue;
    } catch (e, stackTrace) {
      // Failed to parse witr output or something else
      stderr.writeln('Warning: failed to check PID $p: $e\n$stackTrace');
      continue;
    }
  }

  if (skipMessages.isNotEmpty) {
    print('Skipping:');
    var maxPidDigits = 0;
    var maxCmdLen = 0;
    var maxParentPidDigits = 0;

    final groupedParents = <int, ({String name, List<SkipMessage> children})>{};
    final otherSkips = <SkipMessage>[];

    for (final m in skipMessages) {
      final digits = m.pid.toString().length;
      if (digits > maxPidDigits) maxPidDigits = digits;
      final cmdLen = m.cmdline.length;
      if (cmdLen > maxCmdLen) maxCmdLen = cmdLen;

      if (m.parentPid != null && m.parentName != null) {
        final pDigits = m.parentPid!.toString().length;
        if (pDigits > maxParentPidDigits) maxParentPidDigits = pDigits;

        final entry = groupedParents.putIfAbsent(
          m.parentPid!,
          () => (name: m.parentName!, children: []),
        );
        entry.children.add(m);
      } else {
        otherSkips.add(m);
      }
    }

    for (final ppid in groupedParents.keys) {
      final parent = groupedParents[ppid]!;
      final pPidStr = ppid.toString().padLeft(maxParentPidDigits);
      print('  Parent [$pPidStr] ${parent.name}');
      for (final m in parent.children) {
        final pidStr = m.pid.toString().padLeft(maxPidDigits);
        final cmdStr = m.cmdline.padRight(maxCmdLen);
        final cwdStr = (m.cwd != null && m.cwd != '/')
            ? '  ${abbreviatePath(m.cwd!)}'
            : '';
        print('    [$pidStr]  $cmdStr$cwdStr');
      }
    }

    if (otherSkips.isNotEmpty) {
      print('  Other:');
      for (final m in otherSkips) {
        final pidStr = m.pid.toString().padLeft(maxPidDigits);
        final cmdStr = m.cmdline.padRight(maxCmdLen);
        final cwdStr = (m.cwd != null && m.cwd != '/')
            ? '  ${abbreviatePath(m.cwd!)}'
            : '';
        print('    [$pidStr]  $cmdStr$cwdStr  ${m.reason}');
      }
    }

    print('');
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
    await killPids(orphanedPids, force: true);
  } else {
    print('');
    stdout.write('Kill all orphaned processes? (y/N) ');
    final response = stdin.readLineSync();
    if (response?.toLowerCase() == 'y') {
      await killPids(orphanedPids);
    } else {
      print('Skipping kill.');
    }
  }
}

typedef SkipMessage = ({
  int pid,
  String cmdline,
  int? parentPid,
  String? parentName,
  String? cwd,
  String reason,
});

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
