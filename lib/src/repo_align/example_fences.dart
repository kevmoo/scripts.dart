import 'dart:io';

import 'package:path/path.dart' as p;

/// Matches a fenced code block opener whose info string contains `@example`,
/// e.g. ```` ```dart @example example/foo.dart#region ````.
final _exampleFenceRegex = RegExp(
  r'^[ \t>]*(?:`{3,}|~{3,})[^\n`]*@example',
  multiLine: true,
);

/// Whether [markdown] contains a `pkg:example` fence (one whose info string
/// carries `@example`).
bool hasExampleFence(String? markdown) =>
    markdown != null &&
    markdown.contains('@example') &&
    _exampleFenceRegex.hasMatch(markdown);

const _skippedDirNames = {'.git', '.dart_tool', 'node_modules', 'build'};

/// Whether any `.md` file under [repoDir] contains a `pkg:example` fence.
///
/// Mirrors the SPOT scanner's file walk: generated and tooling directories are
/// skipped.
bool hasLocalExampleFences(Directory repoDir) {
  if (!repoDir.existsSync()) return false;
  for (final entity in repoDir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.md')) continue;
    final segments = p.split(p.relative(entity.path, from: repoDir.path));
    if (segments.any(_skippedDirNames.contains)) continue;
    try {
      if (hasExampleFence(entity.readAsStringSync())) return true;
    } on FileSystemException {
      // Unreadable file; skip it.
    } on FormatException {
      // Non-UTF-8 file; it cannot hold a usable fence.
    }
  }
  return false;
}
