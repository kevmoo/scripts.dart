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

  // Find all dart processes
  final pids = <int>{};
  for (final exe in ['dart', 'dartvm']) {
    pids.addAll(await _findPids([exe]));
  }

  // Get current process children so we don't kill them
  final protectedPids = {
    currentPid,
    ...await _findPids(['-P', currentPid.toString()]),
  };

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

  await _handleKill(orphanedPids, force: options.force);
}

Future<List<int>> _findPids(List<String> args) async {
  try {
    final output = await runProcess('pgrep', args);
    return LineSplitter.split(output)
        .where((s) => s.isNotEmpty)
        .map(int.parse)
        .toList();
  } on ProcessException catch (e) {
    if (e.errorCode != 1) rethrow;
    return const [];
  }
}

Future<void> _handleKill(List<int> orphanedPids, {required bool force}) async {
  if (force) {
    await killPids(orphanedPids, force: true);
    return;
  }

  print('');
  stdout.write('Kill all orphaned processes? (y/N) ');
  final response = stdin.readLineSync();
  if (response?.toLowerCase() == 'y') {
    await killPids(orphanedPids);
  } else {
    print('Skipping kill.');
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

  new({this.force = false, this.list = false, this.help = false});
}

String get dartCleanOptionsUsage => _$parserForDartCleanOptions.usage;

ArgParser get dartCleanOptionsParser => _$parserForDartCleanOptions;

class DartCleanException(final String message) implements Exception {
  @override
  String toString() => message;
}

class _ProcessNode({
  required final int pid,
  required final String cmdline,
  final int? parentPid,
  final String? parentName,
  final String? cwd,
  required final String reason,
  final bool isDart = true,
}) {
  final List<_ProcessNode> children = [];

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

class DartProcess({
  required final int pid,
  required final String cmdline,
  final int? ppid,
  final String? parentName,
  final String? cwd,
  required final String reason,
  final bool isDart = true,
  required final List<({int pid, String command})> ancestry,
  final int? ownerPid,
});

Future<DartProcess?> _checkProcess(int p, Set<int> protectedPids) async {
  if (protectedPids.contains(p)) {
    return _checkProtectedProcess(p);
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

    final (:reason, :ownerPid) = await _resolveOwnerReason(
      ppid,
      data.process.env,
    );

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

Future<DartProcess> _checkProtectedProcess(int p) async {
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

Future<({String reason, int? ownerPid})> _resolveOwnerReason(
  int? ppid,
  List<String>? env,
) async {
  if (ppid != 1) {
    return (reason: '', ownerPid: null);
  }

  final vscodePidStr = env
      ?.where((String e) => e.startsWith('VSCODE_PID='))
      .firstOrNull;

  if (vscodePidStr != null) {
    final vscodePid = int.tryParse(vscodePidStr.split('=')[1]);
    if (vscodePid != null && await isProcessRunning(vscodePid)) {
      return (
        reason:
            'parent is launchd, but since VS Code '
            '(PID $vscodePid) is running.',
        ownerPid: vscodePid,
      );
    }
  }

  return (reason: 'Orphaned', ownerPid: null);
}

typedef _PidAncestry = ({int pid, List<({int pid, String command})> ancestry});

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
      .forEach(parentToPid.values, _fetchPidAncestry)
      .where((r) => r != null)
      .cast<_PidAncestry>()
      .toList();

  final ancestries = Map.fromEntries(
    ancestriesList.map((e) => MapEntry(e.pid, e.ancestry)),
  );

  // 4. Build the tree
  return _linkProcessNodes(processes, nodes, parentToPid, ancestries);
}

Future<_PidAncestry?> _fetchPidAncestry(int pid) async {
  final treeResult = await Process.run('witr', [
    '--pid',
    pid.toString(),
    '--tree',
    '--json',
  ]);

  if (treeResult.exitCode != 0 && treeResult.stdout.toString().isEmpty) {
    stderr
      ..writeln(
        'witr --tree failed for PID $pid with exit code '
        '${treeResult.exitCode}',
      )
      ..writeln('Stderr: ${treeResult.stderr}');
    return null;
  }

  try {
    final treeOutput = treeResult.stdout as String;
    final treeData = jsonDecode(treeOutput) as Map<String, dynamic>;
    final ancestryJson = treeData['Ancestry'] as List<dynamic>;
    final ancestry = ancestryJson.map((e) {
      final map = e as Map<String, dynamic>;
      return (pid: map['PID'] as int, command: map['Command'] as String);
    }).toList();

    return (pid: pid, ancestry: ancestry);
  } catch (e) {
    stderr
      ..writeln('Failed to parse ancestry for PID $pid: $e')
      ..writeln('Output was: ${treeResult.stdout}');
    return null;
  }
}

Future<List<_ProcessNode>> _linkProcessNodes(
  List<DartProcess> processes,
  Map<int, _ProcessNode> nodes,
  Map<int, int> parentToPid,
  Map<int, List<({int pid, String command})>> ancestries,
) async {
  final roots = <_ProcessNode>[];

  for (final p in processes) {
    final pid = p.pid;
    final ppid = p.ppid;
    final node = nodes[pid]!;

    if (p.ownerPid != null && nodes[p.ownerPid] != null) {
      nodes[p.ownerPid]!.children.addUnique(node);
      continue;
    }

    if (ppid == null || ppid == 1) {
      roots.addUnique(node);
      continue;
    }

    if (nodes.containsKey(ppid)) {
      nodes[ppid]!.children.addUnique(node);
    } else {
      await _linkNonDartParent(
        node,
        pid,
        ppid,
        nodes,
        parentToPid,
        ancestries,
        roots,
      );
    }
  }
  return roots;
}

Future<void> _linkNonDartParent(
  _ProcessNode node,
  int pid,
  int ppid,
  Map<int, _ProcessNode> nodes,
  Map<int, int> parentToPid,
  Map<int, List<({int pid, String command})>> ancestries,
  List<_ProcessNode> roots,
) async {
  final ancestry = ancestries[pid] ?? ancestries[parentToPid[ppid]];
  if (ancestry == null) {
    roots.addUnique(node);
    return;
  }

  _ProcessNode? prevNode;
  for (final ancestor in ancestry) {
    var aNode = nodes[ancestor.pid];
    if (aNode == null) {
      final cwd = await getProcessCwd(ancestor.pid);
      aNode = _ProcessNode(
        pid: ancestor.pid,
        cmdline: ancestor.command,
        reason: '',
        isDart: false,
        cwd: cwd,
      );
      nodes[ancestor.pid] = aNode;
    }

    if (prevNode == null) {
      roots.addUnique(aNode);
    } else {
      prevNode.children.addUnique(aNode);
    }
    prevNode = aNode;
  }

  if (ancestry.length >= 2) {
    final parentNode = nodes[ancestry[ancestry.length - 2].pid];
    parentNode?.children.addUnique(node);
  }
}

extension on List<_ProcessNode> {
  void addUnique(_ProcessNode node) {
    if (!contains(node)) {
      add(node);
    }
  }
}
