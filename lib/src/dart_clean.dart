import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/ansi.dart';
import 'package:pool/pool.dart';

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

  print('Checking ${pids.length} processes...');

  final pool = Pool(4);
  final results = await pool
      .forEach(pids, (p) => _checkProcess(p, protectedPids))
      .where((r) => r != null)
      .cast<DartProcess>()
      .toList();

  if (results.isNotEmpty) {
    print('Process Tree:');
    final roots = await _buildTree(results);
    for (final root in roots) {
      root.printNode('  ');
    }
    print('');
  }

  final orphaned = results.where((r) => r.reason == 'Orphaned').toList();
  final orphanedPids = orphaned.map((e) => e.pid).toList();

  if (orphaned.isEmpty) {
    print(green.wrap('No orphaned Dart processes found.'));
    return;
  }

  print(yellow.wrap('Found ${orphaned.length} orphaned Dart processes:'));
  for (final p in orphaned) {
    print('  [${yellow.wrap(p.pid.toString())}] ${p.cmdline}');
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

class _ProcessNode {
  final int pid;
  final String cmdline;
  final int? parentPid;
  final String? parentName;
  final String? cwd;
  final String reason;
  final bool isDart;
  final List<_ProcessNode> children = [];

  _ProcessNode({
    required this.pid,
    required this.cmdline,
    this.parentPid,
    this.parentName,
    this.cwd,
    required this.reason,
    this.isDart = true,
  });

  void printNode(String indent) {
    var reasonStr = reason.isNotEmpty ? ' ($reason)' : '';
    if (reason.contains('parent is launchd')) {
      reasonStr = ' (${cyan.wrap(reason)})';
    }
    final cwdStr = (cwd != null && cwd != '/')
        ? '  ${abbreviatePath(cwd!)}'
        : '';
    final pidStr = isDart ? yellow.wrap(pid.toString()) : pid.toString();

    print('$indent[$pidStr] $cmdline$cwdStr$reasonStr');
    for (final child in children) {
      child.printNode('$indent  ');
    }
  }
}

class DartProcess {
  final int pid;
  final String cmdline;
  final int? ppid;
  final String? parentName;
  final String? cwd;
  final String reason;
  final bool isDart;
  final List<({int pid, String command})> ancestry;
  final int? ownerPid;

  DartProcess({
    required this.pid,
    required this.cmdline,
    this.ppid,
    this.parentName,
    this.cwd,
    required this.reason,
    this.isDart = true,
    required this.ancestry,
    this.ownerPid,
  });
}

Future<DartProcess?> _checkProcess(int p, Set<int> protectedPids) async {
  if (protectedPids.contains(p)) {
    final cmdline = formatCmdline(await getProcessCmdline(p));
    final cwd = await getProcessCwd(p);

    final treeResult = await Process.run('witr', [
      '--pid',
      p.toString(),
      '--tree',
      '--json',
    ]);

    var ancestry = <({int pid, String command})>[];
    if (treeResult.exitCode == 0 || treeResult.stdout.toString().isNotEmpty) {
      try {
        final treeOutput = treeResult.stdout as String;
        final treeData = jsonDecode(treeOutput) as Map<String, dynamic>;
        final ancestryJson = treeData['Ancestry'] as List<dynamic>;
        ancestry = ancestryJson.map((e) {
          final map = e as Map<String, dynamic>;
          return (pid: map['PID'] as int, command: map['Command'] as String);
        }).toList();
      } catch (e) {
        // Ignore
      }
    }

    return DartProcess(
      pid: p,
      cmdline: cmdline,
      cwd: cwd,
      reason: 'since it is a protected process (current script or child).',
      ancestry: ancestry,
    );
  }

  try {
    final result = await Process.run('witr', ['--pid', p.toString(), '--json']);

    final witrOutput = result.stdout as String;

    if (witrOutput.trim().isEmpty && result.exitCode != 0) {
      final cmdline = formatCmdline(await getProcessCmdline(p));
      final cwd = await getProcessCwd(p);
      return DartProcess(
        pid: p,
        cmdline: cmdline,
        cwd: cwd,
        reason:
            'since witr failed with exit code ${result.exitCode} '
            'and no output.',
        ancestry: [],
      );
    }

    final data = WitrData.fromJson(
      jsonDecode(witrOutput) as Map<String, dynamic>,
    );

    final ppid = data.process.ppid;
    final parentName = ppid != null ? await getProcessName(ppid) : '<unknown>';

    var reason = '';
    int? ownerPid;
    if (ppid != 1) {
      reason = '';
    } else {
      final vscodePidStr = data.process.env
          ?.where((String e) => e.startsWith('VSCODE_PID='))
          .firstOrNull;

      if (vscodePidStr != null) {
        final vscodePid = int.tryParse(vscodePidStr.split('=')[1]);
        if (vscodePid != null) {
          if (await isProcessRunning(vscodePid)) {
            reason =
                'parent is launchd, but since VS Code '
                '(PID $vscodePid) is running.';
            ownerPid = vscodePid;
          }
        }
      }

      if (reason.isEmpty) {
        reason = 'Orphaned';
      }
    }

    final cwdEnv = data.process.env
        ?.where((String e) => e.startsWith('PWD='))
        .firstOrNull;
    final cwd = cwdEnv != null ? cwdEnv.substring(4) : await getProcessCwd(p);

    return DartProcess(
      pid: p,
      cmdline: formatCmdline(data.process.cmdline),
      ppid: ppid,
      parentName: parentName,
      cwd: cwd,
      reason: reason,
      ancestry: [], // Ancestry will be fetched lazily in _buildTree
      ownerPid: ownerPid,
    );
  } on ProcessException {
    final cmdline = formatCmdline(await getProcessCmdline(p));
    final cwd = await getProcessCwd(p);
    return DartProcess(
      pid: p,
      cmdline: cmdline,
      cwd: cwd,
      reason: 'since process likely exited.',
      ancestry: [],
    );
  } catch (e, stackTrace) {
    stderr.writeln('Warning: failed to check PID $p: $e\n$stackTrace');
    return null;
  }
}

Future<List<_ProcessNode>> _buildTree(List<DartProcess> processes) async {
  final nodes = <int, _ProcessNode>{};

  // 1. Populate with Dart processes
  for (final p in processes) {
    nodes[p.pid] = _ProcessNode(
      pid: p.pid,
      cmdline: p.cmdline,
      parentPid: p.ppid,
      parentName: p.parentName,
      cwd: p.cwd,
      reason: p.reason,
    );
  }

  // 2. Identify unique parents that need ancestry
  final parentToPid = <int, int>{};
  for (final p in processes) {
    final ppid = p.ppid;
    if (ppid != null && ppid != 1 && !nodes.containsKey(ppid)) {
      parentToPid[ppid] = p.pid; // Map parent PID to one of its child Dart PIDs
    }
  }

  // 3. Fetch ancestries concurrently
  final pool = Pool(4);
  final ancestriesList = await pool
      .forEach(parentToPid.values, (pid) async {
        final treeResult = await Process.run('witr', [
          '--pid',
          pid.toString(),
          '--tree',
          '--json',
        ]);

        if (treeResult.exitCode == 0 ||
            treeResult.stdout.toString().isNotEmpty) {
          try {
            final treeOutput = treeResult.stdout as String;
            final treeData = jsonDecode(treeOutput) as Map<String, dynamic>;
            final ancestryJson = treeData['Ancestry'] as List<dynamic>;
            final ancestry = ancestryJson.map((e) {
              final map = e as Map<String, dynamic>;
              return (
                pid: map['PID'] as int,
                command: map['Command'] as String,
              );
            }).toList();

            return (pid: pid, ancestry: ancestry);
          } catch (e) {
            print('Failed to parse ancestry for PID $pid: $e');
            print('Output was: ${treeResult.stdout}');
          }
        } else {
          print(
            'witr --tree failed for PID $pid with exit code '
            '${treeResult.exitCode}',
          );
          print('Stderr: ${treeResult.stderr}');
        }
        return null;
      })
      .where((r) => r != null)
      .cast<({int pid, List<({int pid, String command})> ancestry})>()
      .toList();

  final ancestries = Map.fromEntries(
    ancestriesList.map((e) => MapEntry(e.pid, e.ancestry)),
  );

  // 4. Build the tree
  final roots = <_ProcessNode>[];

  for (final p in processes) {
    final pid = p.pid;
    final ppid = p.ppid;
    final node = nodes[pid]!;

    if (p.ownerPid != null) {
      final ownerNode = nodes[p.ownerPid];
      if (ownerNode != null) {
        if (!ownerNode.children.contains(node)) {
          ownerNode.children.add(node);
        }
        continue;
      }
    }

    if (ppid == null || ppid == 1) {
      if (!roots.contains(node)) {
        roots.add(node);
      }
      continue;
    }

    if (nodes.containsKey(ppid)) {
      // Parent is a Dart process we know about. Link it.
      if (!nodes[ppid]!.children.contains(node)) {
        nodes[ppid]!.children.add(node);
      }
    } else {
      // Parent is non-Dart. We should have fetched ancestry for it!
      final ancestry = ancestries[pid] ?? ancestries[parentToPid[ppid]];

      if (ancestry != null) {
        _ProcessNode? prevNode;
        for (final ancestor in ancestry) {
          final aPid = ancestor.pid;
          final aName = ancestor.command;

          var aNode = nodes[aPid];
          if (aNode == null) {
            final cwd = await getProcessCwd(aPid);
            aNode = _ProcessNode(
              pid: aPid,
              cmdline: aName,
              reason: '',
              isDart: false,
              cwd: cwd,
            );
            nodes[aPid] = aNode;
          }

          if (prevNode == null) {
            if (!roots.contains(aNode)) {
              roots.add(aNode);
            }
          } else {
            if (!prevNode.children.contains(aNode)) {
              prevNode.children.add(aNode);
            }
          }
          prevNode = aNode;
        }

        // Link current node to the parent in ancestry
        if (ancestry.length >= 2) {
          final parentPid = ancestry[ancestry.length - 2].pid;
          final parentNode = nodes[parentPid];
          if (parentNode != null) {
            if (!parentNode.children.contains(node)) {
              parentNode.children.add(node);
            }
          }
        }
      } else {
        // Fallback if ancestry fetch failed
        if (!roots.contains(node)) {
          roots.add(node);
        }
      }
    }
  }
  return roots;
}
