import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/ansi.dart';
import 'package:pool/pool.dart';

import 'process_inspector.dart';
import 'process_utils.dart';
import 'util.dart';

part 'dart_clean.g.dart';

Future<void> runDartClean(
  DartCleanOptions options, {
  ProcessInspector? inspector,
}) async {
  final activeInspector = inspector ?? ProcessInspector.platform();

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
      .forEach(pids, (p) => _checkProcess(p, protectedPids, activeInspector))
      .where((r) => r != null)
      .cast<DartProcess>()
      .toList();

  if (results.isNotEmpty) {
    print('Process Tree:');
    final roots = await _buildTree(results, activeInspector);
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
    if (reason.contains('parent is ')) {
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

Future<DartProcess?> _checkProcess(
  int p,
  Set<int> protectedPids,
  ProcessInspector inspector,
) async {
  if (protectedPids.contains(p)) {
    return _checkProtectedProcess(p, inspector);
  }

  try {
    final info = await inspector.inspect(p);
    if (info == null) {
      return DartProcess(
        pid: p,
        cmdline: '<exited>',
        reason: 'since process likely exited.',
        ancestry: [],
      );
    }

    final ppid = info.ppid;
    final parentName = ppid != null
        ? (await inspector.inspect(ppid))?.name ?? await getProcessName(ppid)
        : '<unknown>';

    final (:reason, :ownerPid) = await _resolveOwnerReason(
      ppid,
      info.env,
      inspector,
    );

    final cwdEnv = info.env
        .where((String e) => e.startsWith('PWD='))
        .firstOrNull;
    final cwd = cwdEnv != null ? cwdEnv.substring(4) : info.cwd;

    return DartProcess(
      pid: p,
      cmdline: formatCmdline(info.cmdline),
      ppid: ppid,
      parentName: parentName,
      cwd: cwd,
      reason: reason,
      ancestry: [],
      ownerPid: ownerPid,
    );
  } catch (e, stackTrace) {
    stderr.writeln('Warning: failed to check PID $p: $e\n$stackTrace');
    return null;
  }
}

Future<DartProcess> _checkProtectedProcess(
  int p,
  ProcessInspector inspector,
) async {
  final info = await inspector.inspect(p);
  final cmdline = info != null ? formatCmdline(info.cmdline) : '<current>';
  final cwd = info?.cwd;
  final ancestry = await inspector.ancestry(p);

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
  ProcessInspector inspector,
) async {
  if (ppid == null) {
    return (reason: '', ownerPid: null);
  }

  final isReaper = await inspector.isReaper(ppid);
  if (!isReaper) {
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
            'parent is ${inspector.reaperName}, but since VS Code '
            '(PID $vscodePid) is running.',
        ownerPid: vscodePid,
      );
    }
  }

  return (reason: 'Orphaned', ownerPid: null);
}

typedef _PidAncestry = ({int pid, List<({int pid, String command})> ancestry});

Future<List<_ProcessNode>> _buildTree(
  List<DartProcess> processes,
  ProcessInspector inspector,
) async {
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
      parentToPid[ppid] = p.pid;
    }
  }

  // 3. Fetch ancestries concurrently
  final pool = Pool(4);
  final ancestriesList = await pool
      .forEach(parentToPid.values, (pid) => _fetchPidAncestry(pid, inspector))
      .where((r) => r != null)
      .cast<_PidAncestry>()
      .toList();

  final ancestries = Map.fromEntries(
    ancestriesList.map((e) => MapEntry(e.pid, e.ancestry)),
  );

  // 4. Build the tree
  return _linkProcessNodes(
    processes,
    nodes,
    parentToPid,
    ancestries,
    inspector,
  );
}

Future<_PidAncestry?> _fetchPidAncestry(
  int pid,
  ProcessInspector inspector,
) async {
  final ancestry = await inspector.ancestry(pid);
  return (pid: pid, ancestry: ancestry);
}

Future<List<_ProcessNode>> _linkProcessNodes(
  List<DartProcess> processes,
  Map<int, _ProcessNode> nodes,
  Map<int, int> parentToPid,
  Map<int, List<({int pid, String command})>> ancestries,
  ProcessInspector inspector,
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

    if (ppid == null || await inspector.isReaper(ppid)) {
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
        inspector,
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
  ProcessInspector inspector,
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
      final ancestorInfo = await inspector.inspect(ancestor.pid);
      final cwd = ancestorInfo?.cwd;
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
