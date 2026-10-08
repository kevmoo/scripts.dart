import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Checks whether the compiled `kscripts` binary is older than the local
/// `scripts.dart` checkout's `main` ref (using `KSCRIPTS_REPO_DIR` or the
/// `dart install` bundle's `../../pubspec.lock` path).
void checkKScriptsStaleness({
  String? repoDirEnv,
  File? executableFile,
  void Function(String)? onStderr,
}) {
  final emit = onStderr ?? (String line) => stderr.writeln(line);
  final exe = executableFile ?? File(Platform.resolvedExecutable);
  final exeName = p.basenameWithoutExtension(exe.path);
  // Skip when running under `dart test` or `dart run` VM executable.
  if (exeName == 'dart' || exeName == 'dartaotruntime') return;

  final explicitDir = repoDirEnv ?? Platform.environment['KSCRIPTS_REPO_DIR'];
  final repoPath = (explicitDir != null && explicitDir.trim().isNotEmpty)
      ? explicitDir.trim()
      : _resolveRepoDirFromBundleLock(exe);

  // No local checkout to compare against (e.g. a `git` or `hosted` install
  // without `KSCRIPTS_REPO_DIR`); stay silent rather than nagging every run.
  if (repoPath == null) return;

  if (!exe.existsSync()) return;
  final mainModified = _mainUpdatedAt(repoPath);
  if (mainModified == null) return;

  try {
    final binModified = File(exe.resolveSymbolicLinksSync())
        .statSync()
        .modified;
    if (mainModified.isAfter(binModified)) {
      emit(
        '⚠️ Note: kscripts binary is older than $repoPath (main). '
        'Run "upkeep update dart_install" to refresh.',
      );
    }
  } catch (_) {}
}

/// When `main` in [repoPath] was last updated, or `null` when there is no such
/// repository or branch.
///
/// Asks `git` rather than stat-ing `.git/refs/heads/main`: that loose file is
/// absent once refs are packed and never exists under the `reftable` backend.
/// Prefers the reflog entry (when the local ref last moved, matching the old
/// mtime semantics) and falls back to the commit time when there is no reflog.
DateTime? _mainUpdatedAt(String repoPath) {
  String? run(List<String> args) {
    try {
      final result = Process.runSync('git', ['-C', repoPath, ...args]);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  // `main@{<unix seconds>}` from the reflog, if one exists.
  final reflog = run([
    'log',
    '-g',
    '-1',
    '--format=%gd',
    '--date=unix',
    'main',
  ]);
  final seconds =
      int.tryParse(
        RegExp(r'@\{(\d+)\}$').firstMatch(reflog ?? '')?.group(1) ?? '',
      ) ??
      int.tryParse(run(['log', '-1', '--format=%ct', 'main']) ?? '');
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

String? _resolveRepoDirFromBundleLock(File exe) {
  try {
    final resolvedExe = File(exe.resolveSymbolicLinksSync());
    // Layout: <app-bundles>/kevmoo_scripts/<source>/<version>/bundle/bin/kscripts
    final lockFile = File(
      p.normalize(p.join(resolvedExe.parent.path, '..', '..', 'pubspec.lock')),
    );
    if (!lockFile.existsSync()) return null;
    final yaml = loadYaml(lockFile.readAsStringSync());
    if (yaml is! YamlMap) return null;
    final packages = yaml['packages'] as YamlMap?;
    final entry = packages?['kevmoo_scripts'] as YamlMap?;
    // Only a `path` install points at a live local checkout. A `git` install
    // records a repo-internal subdirectory (e.g. `path: "."`), which would
    // otherwise resolve against the current working directory.
    if (entry?['source']?.toString() != 'path') return null;
    final desc = entry?['description'] as YamlMap?;
    final rawPath = desc?['path']?.toString();
    if (rawPath == null || rawPath.isEmpty) return null;
    // `relative: true` paths are relative to the lock file, never to the CWD.
    final base = desc?['relative'] == true ? lockFile.parent.path : '';
    final repoDir = p.normalize(p.join(base, rawPath));
    return p.isAbsolute(repoDir) ? repoDir : null;
  } catch (_) {
    return null;
  }
}
