import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'testable_print.dart';

part 'prose_check/prose_extractor.dart';
part 'prose_check/prose_masker.dart';
part 'prose_check/prose_smells.dart';

/// Description for `kscripts prose-check --help` (must match `README.md`).
const proseCheckDescription =
    'Scan Markdown and text documents for prose readability smells.';

final _ignoredWalkDirs = {'node_modules', 'build'};
final _ignoredWalkFiles = 'changelog.md,skill.md,agents.md,claude.md,gemini.md'
    .split(',')
    .toSet();

/// Input syntax mode for `prose-check`.
enum ProseFormat { auto, markdown, text }

/// Document profile used to tune prose smell thresholds.
enum ProseProfile { auto, readme, technical, spec, narrative }

/// Advisory severity tier for a detected [ProseSmell].
enum SmellSeverity { info, smell, high }

/// A single prose readability smell with 1-based source coordinates.
final class ProseSmell {
  final String smellId, summary, excerpt;
  final SmellSeverity severity;
  final int line, column;

  const new({
    required this.smellId,
    required this.severity,
    required this.line,
    required this.column,
    required this.summary,
    required this.excerpt,
  });

  Map<String, Object?> toJson() => {
    'smellId': smellId,
    'severity': severity.name,
    'line': line,
    'column': column,
    'summary': summary,
    'excerpt': excerpt,
  };
}

/// Document-level vitality metrics computed over extracted prose blocks.
final class ProseStats {
  final int proseWords, sentenceCount, sentenceP90Words, sentenceMaxWords;
  final int maxConsecutiveBoldLeads, tableCount, maxTableCellWords;
  final int proseBlocks, maxTableCols;
  final double estimatedReadMinutes, sentenceMeanWords, pctOver30Words;
  final double pctWordsInParens, pillsPer100Words, boldLeadPct;

  const new([
    this.proseWords = 0,
    this.estimatedReadMinutes = 0,
    this.sentenceCount = 0,
    this.sentenceMeanWords = 0,
    this.sentenceP90Words = 0,
    this.sentenceMaxWords = 0,
    this.pctOver30Words = 0,
    this.pctWordsInParens = 0,
    this.pillsPer100Words = 0,
    this.boldLeadPct = 0,
    this.maxConsecutiveBoldLeads = 0,
    this.tableCount = 0,
    this.maxTableCellWords = 0,
    this.proseBlocks = 0,
    this.maxTableCols = 0,
  ]);

  Map<String, Object?> toJson() => {
    'proseWords': proseWords,
    'proseBlocks': proseBlocks,
    'estimatedReadMinutes': estimatedReadMinutes,
    'sentenceCount': sentenceCount,
    'sentenceMeanWords': sentenceMeanWords,
    'sentenceP90Words': sentenceP90Words,
    'sentenceMaxWords': sentenceMaxWords,
    'pctOver30Words': pctOver30Words,
    'pctWordsInParens': pctWordsInParens,
    'pillsPer100Words': pillsPer100Words,
    'boldLeadPct': boldLeadPct,
    'maxConsecutiveBoldLeads': maxConsecutiveBoldLeads,
    'tableCount': tableCount,
    'maxTableCols': maxTableCols,
    'maxTableCellWords': maxTableCellWords,
  };
}

final class _ProfileCaps {
  final double pillsWarn, pillsHigh, boldWarn, boldHigh, parenWarn, parenHigh;
  final double over30Warn, over30High, meanWarn, meanHigh;
  final int boldRunHigh;

  const new(
    this.pillsWarn,
    this.pillsHigh,
    this.boldWarn,
    this.boldHigh,
    this.boldRunHigh,
    this.parenWarn,
    this.parenHigh, [
    this.over30Warn = 12,
    this.over30High = 15,
    this.meanWarn = 22,
    this.meanHigh = 24,
  ]);

  Map<String, Object?> toJson() => {
    'pillsPer100Words': {'smell': pillsWarn, 'high': pillsHigh},
    'boldLeadPct': {
      'smell': boldWarn,
      'high': boldHigh,
      'runHigh': boldRunHigh,
    },
    'pctWordsInParens': {'smell': parenWarn, 'high': parenHigh},
    'pctOver30Words': {'smell': over30Warn, 'high': over30High},
    'sentenceMeanWords': {'smell': meanWarn, 'high': meanHigh},
  };
}

_ProfileCaps _capsFor(ProseProfile p) => switch (p) {
  ProseProfile.narrative => const _ProfileCaps(6, 8, 45, 60, 10, 6.5, 10),
  ProseProfile.spec => const _ProfileCaps(12, 16, 55, 70, 15, 7.5, 12),
  ProseProfile.readme => const _ProfileCaps(
    22,
    25,
    75,
    88,
    22,
    12,
    18,
    14,
    18,
    23,
    25,
  ),
  ProseProfile.auto || ProseProfile.technical => const _ProfileCaps(
    16,
    20,
    65,
    80,
    18,
    9,
    14,
    14,
    18,
    23,
    25,
  ),
};

/// Complete smell-scan result for a single document.
final class ProseCheckReport {
  final String path, profileReason;
  final ProseProfile profile;
  final ProseFormat format;
  final ProseStats stats;
  final List<ProseSmell> smells;
  final Map<String, int> totalSmellCountsById;

  const new({
    required this.path,
    required this.profile,
    required this.format,
    required this.stats,
    required this.smells,
    required this.totalSmellCountsById,
    this.profileReason = '',
  });

  int get highSmellCount =>
      smells.where((s) => s.severity == SmellSeverity.high).length;

  List<ProseSmell> topSmells(int top) => _stratifiedTopSmells(smells, top);

  Map<String, Object?> toJson({int top = 15}) {
    final shown = topSmells(top);
    return {
      'path': path,
      'profile': profile.name,
      'profileReason': profileReason,
      'format': format.name,
      'thresholds': _capsFor(profile).toJson(),
      'totalSmells': smells.length,
      'highSmells': highSmellCount,
      'truncatedSmells': smells.length - shown.length,
      'totalSmellCountsById': totalSmellCountsById,
      'stats': stats.toJson(),
      'smells': [for (final s in shown) s.toJson()],
    };
  }

  String formatText({int top = 15}) {
    final shown = topSmells(top), s = stats;
    final smN = smells.where((x) => x.severity == SmellSeverity.smell).length;
    final inN = smells.where((x) => x.severity == SmellSeverity.info).length;
    final why = profileReason.isEmpty ? '' : ' ($profileReason)';
    final b = StringBuffer()
      ..writeln(
        '=== $path [profile=${profile.name}$why, format=${format.name}] ===',
      )
      ..writeln(
        'Words: ${s.proseWords} (~${s.estimatedReadMinutes}m) | Sents: '
        '${s.sentenceCount} (mean ${s.sentenceMeanWords}w, p90 '
        '${s.sentenceP90Words}w, max ${s.sentenceMaxWords}w, >30w: '
        '${s.pctOver30Words}%)',
      )
      ..writeln(
        'Parens: ${s.pctWordsInParens}% | Pills: ${s.pillsPer100Words}/100w | '
        'Bold: ${s.boldLeadPct}% of ${s.proseBlocks} '
        '(run ${s.maxConsecutiveBoldLeads}) | Tables: ${s.tableCount} '
        '(max ${s.maxTableCols} cols, max cell ${s.maxTableCellWords}w)',
      )
      ..writeln(
        'Smells: ${smells.length} '
        '($highSmellCount high, $smN smell, $inN info)',
      );
    for (final m in shown) {
      final loc = 'L${m.line}:${m.column}'.padRight(9);
      final sev = '[${m.severity.name}]'.padRight(7);
      b.writeln('  $loc $sev ${m.smellId}: ${m.summary} (${m.excerpt})');
    }
    if (smells.length > shown.length) {
      b.writeln('  ... ${smells.length - shown.length} more (--top=0 for all)');
    }
    return b.toString().trimRight();
  }
}

final _specNameKeys = 'prd,spec,rfc,proposal,scope,design'.split(',');
final _narrativeNameKeys = 'strategy,thesis,memo,narrative,vision,readout'
    .split(',');
final _specHeadingKeys = [
  'proposed scope',
  'non-goals',
  'open questions',
  'user journeys',
  'alternatives considered',
  'success metrics',
  'decision requested',
];
final _specSummaryPeers = 'scope,proposed,requirements,open,goals'.split(',');
final _narrativeHeadingKeys = [
  'strategic',
  'thesis',
  'market',
  'implications',
  'outlook',
];
final _readmeHeadingKeys = [
  'installation',
  'quick start',
  'cli options',
  'command-line',
  'subcommands',
];

/// Scans [raw] text synchronously and returns a structured [ProseCheckReport].
ProseCheckReport scanProseDocument(
  String raw, {
  String path = '<memory>',
  ProseProfile profile = ProseProfile.auto,
  ProseFormat format = ProseFormat.auto,
  Directory? baseDir,
}) {
  final fmt = _resolveFormat(path, format);
  final (prof, reason) = _resolveProfile(path, raw, profile);
  if (profile == ProseProfile.auto &&
      p.basename(path).toLowerCase() == 'changelog.md') {
    return ProseCheckReport(
      path: path,
      profile: prof,
      profileReason: 'changelog skipped in auto mode',
      format: fmt,
      stats: const ProseStats(),
      smells: const [],
      totalSmellCountsById: const {},
    );
  }
  final doc = _extractDocument(_maskDocument(raw, format: fmt), prof, fmt);
  return _evaluateSmells(doc, path: path, reason: reason, baseDir: baseDir);
}

ProseFormat _resolveFormat(String path, ProseFormat explicit) =>
    explicit != ProseFormat.auto
    ? explicit
    : (path.toLowerCase().endsWith('.txt')
          ? ProseFormat.text
          : ProseFormat.markdown);

(ProseProfile, String) _resolveProfile(
  String path,
  String raw,
  ProseProfile explicit,
) {
  if (explicit != ProseProfile.auto) return (explicit, 'explicit flag');
  final b = p.basename(path).toLowerCase();
  if (b == 'readme.md' || b.startsWith('readme.')) {
    return (ProseProfile.readme, 'filename readme');
  }
  if (_specNameKeys.any(b.contains)) {
    return (ProseProfile.spec, 'filename keyword');
  }
  if (_narrativeNameKeys.any(b.contains)) {
    return (ProseProfile.narrative, 'filename keyword');
  }
  return _inferProfileFromHeadings(raw);
}

(ProseProfile, String) _inferProfileFromHeadings(String raw) {
  final hs = _topHeadings(raw, maxLines: 60);
  if (hs.isEmpty) return (ProseProfile.technical, 'default technical');
  final joined = hs.join('\n');
  final execSpec =
      joined.contains('executive summary') &&
      _specSummaryPeers.any(joined.contains);
  if (execSpec || _specHeadingKeys.any(joined.contains)) {
    return (ProseProfile.spec, 'document headings');
  }
  if (_narrativeHeadingKeys.any(joined.contains)) {
    return (ProseProfile.narrative, 'document headings');
  }
  return _readmeHeadingKeys.any(joined.contains)
      ? (ProseProfile.readme, 'document headings')
      : (ProseProfile.technical, 'default technical');
}

List<String> _topHeadings(String raw, {required int maxLines}) {
  final out = <String>[];
  var pos = 0;
  for (var n = 0; n < maxLines && pos < raw.length; n++) {
    final nl = raw.indexOf('\n', pos);
    final end = nl < 0 ? raw.length : nl;
    final t = raw.substring(pos, end).trimLeft();
    if (t.startsWith('#')) out.add(t.toLowerCase());
    pos = end + 1;
  }
  return out;
}

ArgParser _buildProseCheckParser() => ArgParser()
  ..addOption(
    'profile',
    abbr: 'p',
    allowed: [for (final v in ProseProfile.values) v.name],
    defaultsTo: 'auto',
    help: 'Profile threshold preset.',
  )
  ..addOption(
    'format',
    abbr: 'f',
    allowed: [for (final v in ProseFormat.values) v.name],
    defaultsTo: 'auto',
    help: 'Syntax mode (.txt defaults to text).',
  )
  ..addOption('top', abbr: 't', defaultsTo: '15', help: 'Max hotspots (0=all).')
  ..addFlag('json', negatable: false, help: 'Emit compact JSON output.')
  ..addFlag('fail-on-smells', negatable: false, help: 'Exit 1 on high smells.')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage info.');

/// CLI entrypoint for `kscripts prose-check`.
Future<void> runProseCheckCli(
  List<String> arguments, {
  FutureOr<String> Function()? readStdin,
}) async {
  final parser = _buildProseCheckParser();
  final r = _parseCliArgsOrNull(parser, arguments);
  if (r == null) return;
  final top = int.tryParse(r['top'] as String);
  if (top == null || top < 0 || r.rest.isEmpty) {
    final msg = (top == null || top < 0)
        ? 'Invalid --top "${r['top']}": expected integer >= 0.'
        : 'No input files, directories, or "-" specified.';
    return setError(message: '$msg\n\n${parser.usage}', exitCode: 64);
  }
  final mode = (
    ProseProfile.values.byName(r['profile'] as String),
    ProseFormat.values.byName(r['format'] as String),
  );
  final stdinFn = readStdin ?? () => utf8.decodeStream(stdin);
  final reports = await _scanAllTargets(r.rest, mode, stdinFn);
  if (reports == null) return;
  _emitProseOutput(reports, top, json: r['json'] as bool);
  final hi = reports.fold<int>(0, (sum, x) => sum + x.highSmellCount);
  if ((r['fail-on-smells'] as bool) && hi > 0) {
    setError(message: 'Found $hi high-severity prose smell(s).', exitCode: 1);
  }
}

ArgResults? _parseCliArgsOrNull(ArgParser p, List<String> args) {
  try {
    final r = p.parse(args);
    if (!(r['help'] as bool)) return r;
    print(proseCheckDescription);
    print('\nUsage: kscripts prose-check [options] <paths|->\n\n${p.usage}');
    return null;
  } on FormatException catch (e) {
    setError(message: '${e.message}\n\n${p.usage}', exitCode: 64);
    return null;
  }
}

void _emitProseOutput(
  List<ProseCheckReport> reps,
  int top, {
  required bool json,
}) {
  if (!json) {
    return print([for (final r in reps) r.formatText(top: top)].join('\n\n'));
  }
  final all = reps.fold<int>(0, (s, r) => s + r.smells.length);
  final hi = reps.fold<int>(0, (s, r) => s + r.highSmellCount);
  final files = [for (final r in reps) r.toJson(top: top)];
  print(
    jsonEncode({'totalSmellCount': all, 'highSmellCount': hi, 'files': files}),
  );
}

Future<List<ProseCheckReport>?> _scanAllTargets(
  List<String> targets,
  (ProseProfile, ProseFormat) mode,
  FutureOr<String> Function() readStdin,
) async {
  final out = <ProseCheckReport>[];
  for (final t in targets) {
    final batch = t == '-'
        ? [
            scanProseDocument(
              await readStdin(),
              path: '<stdin>',
              profile: mode.$1,
              format: mode.$2,
            ),
          ]
        : _scanDiskTarget(t, mode);
    if (batch == null) return null;
    out.addAll(batch);
  }
  return out;
}

List<ProseCheckReport>? _scanDiskTarget(
  String t,
  (ProseProfile, ProseFormat) m,
) => switch (FileSystemEntity.typeSync(t)) {
  FileSystemEntityType.file => [_scanFile(File(t), t, m)],
  FileSystemEntityType.directory => [
    for (final c in _collectDirDocs(Directory(t))) _scanFile(c, c.path, m),
  ],
  _ => _reportMissingTarget(t),
};

Null _reportMissingTarget(String t) {
  setError(
    message: 'Input path not found: "$t".',
    exitCode: ExitCode.noInput.code,
  );
  return null;
}

ProseCheckReport _scanFile(
  File f,
  String path,
  (ProseProfile, ProseFormat) m,
) => scanProseDocument(
  f.readAsStringSync(),
  path: path,
  profile: m.$1,
  format: m.$2,
  baseDir: f.parent,
);

List<File> _collectDirDocs(Directory root) => [
  for (final e in root.listSync(recursive: true, followLinks: false))
    if (e is File && _includeWalkFile(p.relative(e.path, from: root.path))) e,
]..sort((a, b) => a.path.compareTo(b.path));

bool _includeWalkFile(String rel) {
  if (p
      .split(rel)
      .any((s) => s.startsWith('.') || _ignoredWalkDirs.contains(s))) {
    return false;
  }
  final b = p.basename(rel).toLowerCase();
  return !_ignoredWalkFiles.contains(b) &&
      (b.endsWith('.md') || b.endsWith('.txt'));
}

List<ProseSmell> _stratifiedTopSmells(List<ProseSmell> smells, int top) {
  if (top <= 0 || smells.length <= top) return smells;
  final picked = <ProseSmell>[];
  for (final sev in const [
    SmellSeverity.high,
    SmellSeverity.smell,
    SmellSeverity.info,
  ]) {
    if (picked.length >= top) break;
    picked.addAll(_roundRobinBySmellId(smells, sev, top - picked.length));
  }
  return picked..sort(_compareSmells);
}

List<ProseSmell> _roundRobinBySmellId(
  List<ProseSmell> smells,
  SmellSeverity sev,
  int limit,
) {
  final buckets = <String, List<ProseSmell>>{};
  for (final s in smells) {
    if (s.severity == sev) (buckets[s.smellId] ??= []).add(s);
  }
  final out = <ProseSmell>[];
  for (var round = 0; out.length < limit; round++) {
    final step = _takeRound(buckets.values, round, limit - out.length);
    if (step.isEmpty) break;
    out.addAll(step);
  }
  return out;
}

List<ProseSmell> _takeRound(
  Iterable<List<ProseSmell>> groups,
  int round,
  int rem,
) => [
  for (final g in groups)
    if (round < g.length) g[round],
].take(rem).toList();
