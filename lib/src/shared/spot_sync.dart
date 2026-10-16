import 'dart:io';

import 'package:path/path.dart' as p;

final _spotDefBeginRegex = RegExp(
  r'^\s*<!--\s*SPOT_DEF:\s*([a-z0-9-]+)\s*-->\s*$',
);
final _spotDefEndRegex = RegExp(
  r'^\s*<!--\s*END_SPOT_DEF:\s*([a-z0-9-]+)\s*-->\s*$',
);
final _spotBeginRegex = RegExp(
  r'^(\s*)<!--\s*BEGIN SPOT:\s*([a-z0-9-]+)\s*-->\s*$',
);
final _spotEndRegex = RegExp(r'^\s*<!--\s*END SPOT:\s*([a-z0-9-]+)\s*-->\s*$');
final _codeFenceRegex = RegExp(r'^\s*(`{3,}|~{3,})(.*)$');
final _unorderedBulletRegex = RegExp(r'^([*+-])\s+(.*)$');
final _orderedBulletRegex = RegExp(r'^(\d+\.)\s+(.*)$');
final _structuralLineStartRegex = RegExp(r'^(?:-\s|\d+\.\s|#+\s|>|\||<!--)');

/// A single SPOT block marker or content synchronization issue in a file.
final class SpotDriftIssue {
  final String relPath;
  final String blockId;
  final int lineNumber;
  final String kind;
  final String message;
  final String remediation;

  const new({
    required this.relPath,
    required this.blockId,
    required this.lineNumber,
    required this.kind,
    required this.message,
    required this.remediation,
  });
}

/// Default canonical source files defining `<!-- SPOT_DEF: <id> -->` blocks.
List<File> defaultCanonicalSpotSourceFiles({String? homeDir}) {
  final home = homeDir ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) return const [];
  return [
    File(p.join(home, '.agents', 'CODING_STANDARDS.md')),
    File(p.join(home, 'AGENTS.md')),
    File(p.join(home, '.agents', 'AGENT_DOCS_STANDARDS.md')),
  ];
}

/// Loads all canonical `SPOT_DEF` blocks from [sourceFiles] (or default
/// `$HOME/.agents/` and `$HOME/AGENTS.md` files if omitted).
///
/// Returns an empty map if none of the canonical files exist on disk (e.g. on
/// clean CI runners).
Map<String, String> loadCanonicalSpotDefs({
  String? homeDir,
  List<File>? sourceFiles,
}) {
  final files =
      sourceFiles ?? defaultCanonicalSpotSourceFiles(homeDir: homeDir);
  final defs = <String, String>{};
  for (final file in files) {
    if (!file.existsSync()) continue;
    defs.addAll(extractSpotDefsFromText(file.readAsStringSync()));
  }
  return defs;
}

/// Extracts `<!-- SPOT_DEF: <id> --> ... <!-- END_SPOT_DEF: <id> -->` blocks
/// from [text], stripping common leading indentation.
Map<String, String> extractSpotDefsFromText(String text) {
  final lines = text.split('\n');
  final defs = <String, String>{};
  String? activeId;
  var buffer = <String>[];

  for (final line in lines) {
    final beginMatch = _spotDefBeginRegex.firstMatch(line);
    if (beginMatch != null) {
      activeId = beginMatch.group(1)!;
      buffer = <String>[];
      continue;
    }
    final endMatch = _spotDefEndRegex.firstMatch(line);
    if (endMatch != null && activeId == endMatch.group(1)) {
      defs[activeId!] = dedentSpotLines(buffer).join('\n').trim();
      activeId = null;
      continue;
    }
    if (activeId != null) {
      buffer.add(line);
    }
  }
  return defs;
}

/// Strips empty leading/trailing lines and common leading indentation from
/// [lines].
List<String> dedentSpotLines(List<String> lines) {
  var start = 0;
  while (start < lines.length && lines[start].trim().isEmpty) {
    start++;
  }
  var end = lines.length;
  while (end > start && lines[end - 1].trim().isEmpty) {
    end--;
  }
  if (start >= end) return const [];

  final trimmedRange = lines.sublist(start, end);
  var minIndent = 999999;
  for (final line in trimmedRange) {
    if (line.trim().isEmpty) continue;
    final leading = line.length - line.trimLeft().length;
    if (leading < minIndent) minIndent = leading;
  }
  if (minIndent == 999999 || minIndent == 0) {
    return trimmedRange.map((l) => l.trimRight()).toList();
  }
  return trimmedRange
      .map((l) => l.trim().isEmpty ? '' : l.substring(minIndent).trimRight())
      .toList();
}

/// Normalizes a Markdown block so that Prettier line-wrapping differences at
/// different column indentation levels compare equal while any semantic text,
/// bullet, or code change produces a diff.
String canonicalizeSpotMarkdown(String rawText) {
  final lines = dedentSpotLines(rawText.split('\n'));
  final blocks = <String>[];
  final currentParagraph = StringBuffer();
  String? activeFence;

  void flush() {
    if (currentParagraph.isEmpty) return;
    blocks.add(currentParagraph.toString());
    currentParagraph.clear();
  }

  for (final rawLine in lines) {
    final nextFence = _nextFenceDelimiter(activeFence, rawLine);
    if (nextFence != activeFence) {
      flush();
      activeFence = nextFence;
      blocks.add(rawLine.trim());
    } else if (activeFence != null) {
      blocks.add(rawLine.trimRight());
    } else {
      _appendProseLineToParagraph(rawLine, currentParagraph, flush);
    }
  }

  flush();
  return blocks.join('\n');
}

String? _nextFenceDelimiter(String? activeFence, String rawLine) {
  final fenceMatch = _codeFenceRegex.firstMatch(rawLine);
  if (fenceMatch == null) return activeFence;
  final delimiter = fenceMatch.group(1)!;
  final rest = fenceMatch.group(2)!.trim();
  if (activeFence == null) return delimiter;
  return (delimiter.startsWith(activeFence) && rest.isEmpty)
      ? null
      : activeFence;
}

void _appendProseLineToParagraph(
  String rawLine,
  StringBuffer currentParagraph,
  void Function() flush,
) {
  final normalized = _normalizeProseLine(rawLine);
  if (normalized.isEmpty) {
    flush();
  } else if (_structuralLineStartRegex.hasMatch(normalized)) {
    flush();
    currentParagraph.write(normalized);
  } else if (currentParagraph.isEmpty) {
    currentParagraph.write(normalized);
  } else {
    currentParagraph.write(' $normalized');
  }
}

String _normalizeProseLine(String rawLine) {
  final trimmed = rawLine.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) return '';
  final unordered = _unorderedBulletRegex.firstMatch(trimmed);
  if (unordered != null) return '- ${unordered.group(2)!}';
  final ordered = _orderedBulletRegex.firstMatch(trimmed);
  if (ordered != null) return '${ordered.group(1)!} ${ordered.group(2)!}';
  return trimmed;
}

/// Validates `<!-- BEGIN SPOT: <id> --> ... <!-- END SPOT: <id> -->` blocks in
/// [lines] from [relPath] for balanced markers and content parity against
/// [canonicalDefs].
List<SpotDriftIssue> checkSpotBlocksInLines(
  String relPath,
  List<String> lines, {
  Map<String, String>? canonicalDefs,
}) {
  final defs = canonicalDefs ?? loadCanonicalSpotDefs();
  final issues = <SpotDriftIssue>[];
  String? activeId;
  var activeStartLine = 0;
  var buffer = <String>[];

  for (var i = 0; i < lines.length; i++) {
    final lineNum = i + 1;
    final line = lines[i];
    final beginId = _spotBeginRegex.firstMatch(line)?.group(2);
    if (beginId != null) {
      if (activeId != null) {
        issues.add(_unclosedBeginIssue(relPath, activeId, activeStartLine));
      }
      activeId = beginId;
      activeStartLine = lineNum;
      buffer = <String>[];
      continue;
    }

    final endId = _spotEndRegex.firstMatch(line)?.group(1);
    if (endId != null) {
      final issue = _resolveEndSpotMarker(
        relPath: relPath,
        activeId: activeId,
        endId: endId,
        startLine: activeStartLine,
        endLine: lineNum,
        bodyLines: buffer,
        canonicalDefs: defs,
      );
      if (issue != null) issues.add(issue);
      activeId = null;
      continue;
    }

    if (activeId != null) buffer.add(line);
  }

  if (activeId != null) {
    issues.add(_unclosedBeginIssue(relPath, activeId, activeStartLine));
  }
  return issues;
}

SpotDriftIssue? _resolveEndSpotMarker({
  required String relPath,
  required String? activeId,
  required String endId,
  required int startLine,
  required int endLine,
  required List<String> bodyLines,
  required Map<String, String> canonicalDefs,
}) {
  if (activeId == null) return _unmatchedEndIssue(relPath, endId, endLine);
  if (activeId != endId) {
    return _mismatchedEndIssue(relPath, activeId, endId, startLine, endLine);
  }
  return _verifySpotBlockBody(
    relPath: relPath,
    blockId: activeId,
    startLine: startLine,
    bodyLines: bodyLines,
    canonicalDefs: canonicalDefs,
  );
}

SpotDriftIssue? _verifySpotBlockBody({
  required String relPath,
  required String blockId,
  required int startLine,
  required List<String> bodyLines,
  required Map<String, String> canonicalDefs,
}) {
  final bodyText = bodyLines.join('\n').trim();
  if (bodyText.isEmpty) {
    return SpotDriftIssue(
      relPath: relPath,
      blockId: blockId,
      lineNumber: startLine,
      kind: 'spot-empty-block',
      message: '$relPath:$startLine has an empty SPOT block "$blockId".',
      remediation:
          'Run `kscripts repo-align fix --spot` to populate "$blockId".',
    );
  }
  if (canonicalDefs.isEmpty) return null;

  final expected = canonicalDefs[blockId];
  if (expected == null) {
    return SpotDriftIssue(
      relPath: relPath,
      blockId: blockId,
      lineNumber: startLine,
      kind: 'spot-unknown-id',
      message:
          '$relPath:$startLine references unknown SPOT block ID "$blockId" '
          '(known IDs: ${canonicalDefs.keys.join(', ')}).',
      remediation:
          'Define `<!-- SPOT_DEF: $blockId -->` in `~/.agents/CODING_STANDARDS.md` '
          'or `~/AGENTS.md`, or fix the block ID in $relPath.',
    );
  }

  if (canonicalizeSpotMarkdown(bodyText) !=
      canonicalizeSpotMarkdown(expected)) {
    return SpotDriftIssue(
      relPath: relPath,
      blockId: blockId,
      lineNumber: startLine,
      kind: 'spot-content-drift',
      message:
          '$relPath:$startLine SPOT block "$blockId" has drifted from its '
          'canonical `SPOT_DEF: $blockId` definition.',
      remediation:
          'Edit the canonical `SPOT_DEF: $blockId` block in `~/.dotfiles` and '
          'run `kscripts repo-align fix --spot` or '
          '`kscripts repo-align apply`.',
    );
  }
  return null;
}

SpotDriftIssue _unclosedBeginIssue(String relPath, String id, int line) =>
    SpotDriftIssue(
      relPath: relPath,
      blockId: id,
      lineNumber: line,
      kind: 'spot-unclosed-begin',
      message:
          '$relPath:$line opens `<!-- BEGIN SPOT: $id -->` without a matching '
          '`<!-- END SPOT: $id -->`.',
      remediation: 'Add `<!-- END SPOT: $id -->` after the block in $relPath.',
    );

SpotDriftIssue _unmatchedEndIssue(String relPath, String id, int line) =>
    SpotDriftIssue(
      relPath: relPath,
      blockId: id,
      lineNumber: line,
      kind: 'spot-unmatched-end',
      message:
          '$relPath:$line has `<!-- END SPOT: $id -->` without a preceding '
          '`<!-- BEGIN SPOT: $id -->`.',
      remediation:
          'Add `<!-- BEGIN SPOT: $id -->` or remove the stray end tag.',
    );

SpotDriftIssue _mismatchedEndIssue(
  String relPath,
  String openId,
  String closeId,
  int startLine,
  int endLine,
) => SpotDriftIssue(
  relPath: relPath,
  blockId: openId,
  lineNumber: endLine,
  kind: 'spot-mismatched-end',
  message:
      '$relPath:$endLine closes `<!-- END SPOT: $closeId -->` while '
      '`<!-- BEGIN SPOT: $openId -->` (line $startLine) is open.',
  remediation: 'Align the SPOT block IDs on lines $startLine and $endLine.',
);

/// Replaces all `<!-- BEGIN SPOT: <id> --> ... <!-- END SPOT: <id> -->` regions
/// in [text] with the canonical content from [canonicalDefs], indented to match
/// the `<!-- BEGIN SPOT: <id> -->` marker's column offset.
String stampSpotBlocksInText(String text, Map<String, String> canonicalDefs) {
  final lines = text.split('\n');
  final out = <String>[];
  var i = 0;

  while (i < lines.length) {
    final beginMatch = _spotBeginRegex.firstMatch(lines[i]);
    if (beginMatch == null) {
      out.add(lines[i]);
      i++;
      continue;
    }

    final indent = beginMatch.group(1)!;
    final id = beginMatch.group(2)!;
    final canonical = canonicalDefs[id];
    final endIdx = _findMatchingSpotEndIndex(lines, i + 1, id);

    if (canonical == null || endIdx == -1) {
      out.add(lines[i]);
      i++;
      continue;
    }

    out.addAll(_renderStampedSpotLines(indent, id, canonical));
    i = endIdx + 1;
  }

  return out.join('\n');
}

int _findMatchingSpotEndIndex(List<String> lines, int startIndex, String id) {
  for (var j = startIndex; j < lines.length; j++) {
    final endMatch = _spotEndRegex.firstMatch(lines[j]);
    if (endMatch != null && endMatch.group(1) == id) return j;
    if (_spotBeginRegex.hasMatch(lines[j])) return -1;
  }
  return -1;
}

List<String> _renderStampedSpotLines(
  String indent,
  String id,
  String canonical,
) => [
  '$indent<!-- BEGIN SPOT: $id -->',
  '',
  for (final defLine in dedentSpotLines(canonical.split('\n')))
    defLine.isEmpty ? '' : '$indent$defLine',
  '',
  '$indent<!-- END SPOT: $id -->',
];

/// Discovers all Markdown files in [repoDir] that contain `<!-- BEGIN SPOT:` or
/// `<!-- END SPOT:` markers.
List<String> findSpotMarkdownFiles(Directory repoDir) {
  if (!repoDir.existsSync()) return const [];
  final results = <String>[];
  final entities = repoDir.listSync(recursive: true, followLinks: false);
  for (final entity in entities.whereType<File>()) {
    if (!entity.path.endsWith('.md')) continue;
    final relPath = p.relative(entity.path, from: repoDir.path);
    final segments = p.split(relPath);
    if (segments.any(
      (s) =>
          s == '.git' ||
          s == '.dart_tool' ||
          s == 'node_modules' ||
          s == 'build',
    )) {
      continue;
    }
    final content = entity.readAsStringSync();
    if (content.contains('BEGIN SPOT:') || content.contains('END SPOT:')) {
      results.add(relPath);
    }
  }
  results.sort();
  return results;
}

/// Scans all Markdown files in [repoDir] for SPOT marker or content drift.
List<SpotDriftIssue> scanRepoSpotDrift(
  Directory repoDir, {
  Map<String, String>? canonicalDefs,
}) {
  final defs = canonicalDefs ?? loadCanonicalSpotDefs();
  final issues = <SpotDriftIssue>[];
  for (final relPath in findSpotMarkdownFiles(repoDir)) {
    final file = File(p.join(repoDir.path, relPath));
    issues.addAll(
      checkSpotBlocksInLines(
        relPath,
        file.readAsLinesSync(),
        canonicalDefs: defs,
      ),
    );
  }
  return issues;
}

/// Stamps canonical `SPOT_DEF` blocks into all `<!-- BEGIN SPOT: <id> -->`
/// files in [repoDir] and formats touched files with Prettier (`3.9.6`).
///
/// Refuses to write into `~/.agents/skills` (`npx skills` managed output).
/// Returns the repository-relative paths of files that were (or would be)
/// updated.
List<String> applyRepoSpotStamping(
  Directory repoDir, {
  Map<String, String>? canonicalDefs,
  bool dryRun = false,
  bool runPrettier = true,
}) {
  final normPath = p.normalize(repoDir.absolute.path);
  if (normPath.contains('${p.separator}.agents${p.separator}skills')) {
    throw ArgumentError(
      'Refusing to stamp SPOT blocks into npx-skills managed directory: '
      '$normPath. Target the source repository instead.',
    );
  }

  final defs = canonicalDefs ?? loadCanonicalSpotDefs();
  if (defs.isEmpty) return const [];

  final updatedRelPaths = <String>[];
  for (final relPath in findSpotMarkdownFiles(repoDir)) {
    final file = File(p.join(repoDir.path, relPath));
    final original = file.readAsStringSync();
    final hasDrift =
        checkSpotBlocksInLines(
          relPath,
          original.split('\n'),
          canonicalDefs: defs,
        ).any(
          (i) => i.kind == 'spot-content-drift' || i.kind == 'spot-empty-block',
        );
    if (!hasDrift) continue;
    final stamped = stampSpotBlocksInText(original, defs);

    updatedRelPaths.add(relPath);
    if (!dryRun) {
      file.writeAsStringSync(stamped);
    }
  }

  if (!dryRun && runPrettier && updatedRelPaths.isNotEmpty) {
    Process.runSync('npx', [
      '--yes',
      'prettier@3.9.6',
      '--write',
      ...updatedRelPaths,
    ], workingDirectory: repoDir.path);
  }
  return updatedRelPaths;
}
