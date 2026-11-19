part of '../prose_check.dart';

final _nestedParenRegex = RegExp(
  r'\([^()]*\([^()]*\)[^()]*\)|\u2014[^\u2014]*\([^()]*\)[^\u2014]*\u2014',
);
final _parenGroupRegex = RegExp(r'\(([^()]*)\)');
final _seeParenRegex = RegExp(
  r'^\(\s*(?:see|cf\.?)\b([^()]*)\)$',
  caseSensitive: false,
);
final _subordinateOpenRegex = RegExp(
  r'\b(?:which|where|while|because|although|unless|whereas)\b',
  caseSensitive: false,
);
final _clauseVerbRegex = RegExp(
  r'\b(?:is|are|was|were|has|have|had|does|did|can|could|will|would|should|'
  r'must|fell|grew|dropped|inflated|revealed|preventing|excluding|requiring|'
  r'keeping|causing|succeeding|resolving|overriding|meaning|forcing|leaving|'
  r'declares|requires|allows|ensures|tracks|writes|reads|produces|causes)\b',
  caseSensitive: false,
);
final _domainOrRepoPathRegex = RegExp(
  r'\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/[A-Za-z0-9_./#-]+|(?:^|(?<=[\s(]))'
  r'(?://|(?:lib|bin|test|tool|pkg|packages|docs|skills|scripts|web|example|'
  r'src|references)/)[A-Za-z0-9_./-]+|\b[A-Za-z0-9_-]+(?:/[A-Za-z0-9_.-]+)+\.'
  r'(?:dart|py|go|js|ts|md|txt|yaml|yml|json|cc|h|sh|sql)\b|\b[a-z]{2,10}/'
  r'[A-Za-z0-9_./#-]*\d[A-Za-z0-9_./#-]*',
);
final _codeSlashChainRegex = RegExp(r'\uE000(?:\s*/\s*\uE000)+');
final _slash3ChainRegex = RegExp(
  r'\b[A-Za-z0-9+#_-]{2,}/[A-Za-z0-9+#_.-]{2,}/[A-Za-z0-9+#_.-]{2,}'
  r'(?:/[A-Za-z0-9+#_.-]{2,})*\b',
);
final _slashPairRegex = RegExp(
  r'\b[A-Za-z0-9+#_.-]{2,}\s*/\s*[A-Za-z0-9+#_.-]{2,}\b',
);
final _tildePctRangeRegex = RegExp(
  r'(?:\b(?:illustrative|hypothetical|rough|guessed)\s+)?'
  r'~\s*\d+(?:\.\d+)?%?\s*(?:to|-|\u2013)\s*~?\d+(?:\.\d+)?%'
  r'|\b(?:illustrative|hypothetical|rough|guessed)\s+~?\d+(?:\.\d+)?%',
  caseSensitive: false,
);
final _htmlEntityRegex = RegExp(r'&[A-Za-z0-9#]+;');
final _allowedSlash3 = 'html/css/js,ci/cd/ct,r/w/x,yyyy/mm/dd,mm/dd/yyyy'
    .split(',')
    .toSet();

ProseCheckReport _evaluateSmells(
  _ExtractedDoc doc, {
  required String path,
  Directory? baseDir,
}) {
  final (stats, sentSmells) = _computeProseStats(doc);
  final smells = <ProseSmell>[
    ..._checkLinkSmells(doc.mask, baseDir),
    ..._checkInlineCodeSmells(doc.mask, doc.profile),
    ..._checkBlockAndHeadingSmells(doc),
    ...sentSmells,
    ..._checkTableCells(doc),
    ..._checkMicroTables(doc),
    ..._checkDocAggregates(doc, stats),
  ]..sort(_compareSmells);
  final counts = <String, int>{};
  for (final s in smells) {
    counts[s.smellId] = (counts[s.smellId] ?? 0) + 1;
  }
  return ProseCheckReport(
    path: path,
    profile: doc.profile,
    format: doc.format,
    stats: stats,
    smells: smells,
    totalSmellCountsById: counts,
  );
}

int _compareSmells(ProseSmell a, ProseSmell b) {
  final bySev = b.severity.index.compareTo(a.severity.index);
  if (bySev != 0) return bySev;
  final byLine = a.line.compareTo(b.line);
  return byLine != 0 ? byLine : a.column.compareTo(b.column);
}

double _r1(double v) => (v * 10).roundToDouble() / 10;
double _pct(num part, int whole) => whole == 0 ? 0 : _r1(100.0 * part / whole);

(ProseStats, List<ProseSmell>) _computeProseStats(_ExtractedDoc doc) {
  final proseBlocks = [
    for (final b in doc.blocks)
      if (!b.isHeading) b,
  ];
  final (labeled, maxRun) = _countBoldLeads(proseBlocks);
  final (sentWords, parenW, pills, sentSmells) = _scanBlockSentences(
    doc.mask,
    proseBlocks,
  );
  final sorted = List.of(sentWords)..sort();
  final sc = sorted.length, totalW = sorted.fold<int>(0, (a, b) => a + b);
  final cells = [for (final t in doc.tables) ...t.$5];
  final maxCell = cells.fold<int>(0, (m, c) => math.max(m, c.$2));
  return (
    ProseStats(
      totalW,
      _r1(totalW / 200.0),
      sc,
      sc == 0 ? 0 : _r1(totalW / sc),
      sc == 0 ? 0 : sorted[((sc - 1) * 0.9).round()],
      sc == 0 ? 0 : sorted.last,
      _pct(sorted.where((w) => w > 30).length, sc),
      _pct(parenW, totalW),
      _pct(pills, totalW),
      _pct(labeled, proseBlocks.length),
      maxRun,
      doc.tables.length,
      maxCell,
    ),
    sentSmells,
  );
}

(List<int>, int, int, List<ProseSmell>) _scanBlockSentences(
  _MaskedDoc mask,
  List<_ProseBlock> blocks,
) {
  final words = <int>[], smells = <ProseSmell>[];
  var parenW = 0, pills = 0;
  for (final blk in blocks) {
    pills += _codeSentinelChar.allMatches(blk.maskedSlice).length;
    for (final s in blk.sentences) {
      words.add(s.$3);
      final (pw, sm) = _analyzeSentence(mask, s);
      parenW += pw;
      smells.addAll(sm);
    }
  }
  return (words, parenW, pills, smells);
}

(int, int) _countBoldLeads(List<_ProseBlock> blocks) {
  var labeled = 0, run = 0, maxRun = 0;
  for (final b in blocks) {
    if (!b.hasBoldOrItalicLead) {
      run = 0;
    } else {
      labeled++;
      if (++run > maxRun) maxRun = run;
    }
  }
  return (labeled, maxRun);
}

List<ProseSmell> _checkBlockAndHeadingSmells(_ExtractedDoc doc) {
  final em = doc.profile == ProseProfile.readme
      ? SmellSeverity.info
      : SmellSeverity.smell;
  return [
    for (final b in doc.blocks)
      ...(b.isHeading
          ? _headingSmells(doc.mask.lineIndex, b, em)
          : _blockSmells(doc.mask.lineIndex, b, em)),
  ];
}

List<ProseSmell> _headingSmells(
  _LineIndex idx,
  _ProseBlock b,
  SmellSeverity em,
) {
  final out = _emDashSmells(idx, b.startOffset, b.maskedSlice, em);
  if (b.headingLevel < 2) return out;
  final p = _parenGroupRegex.allMatches(b.maskedSlice).toList();
  if (p.length >= 2) {
    return [
      ...out,
      idx.hi(
        b.startOffset + p.first.start,
        'multi-paren-sentence: ${p.length} parens in heading',
      ),
    ];
  }
  if (p.length == 1 && _countWords(p.first[1]!) > 6) {
    return [
      ...out,
      idx.sm(
        b.startOffset + p.first.start,
        'long-or-clause-paren: Heading paren >6w',
      ),
    ];
  }
  return out;
}

List<ProseSmell> _blockSmells(_LineIndex idx, _ProseBlock b, SmellSeverity em) {
  final out = <ProseSmell>[
    if (b.leadOpenParenOffset case final off?)
      idx.hi(off, 'bold-lead-paren: Paren in bullet lead'),
    ..._emDashSmells(
      idx,
      b.startOffset + b.bodyRelOffset,
      b.maskedSlice.substring(b.bodyRelOffset),
      em,
    ),
    for (final m in _nestedParenRegex.allMatches(b.maskedSlice))
      idx.hi(
        b.startOffset + m.start,
        'nested-parens: Nested parens in prose',
        idx.spanEx(b.startOffset + m.start, m.end - m.start),
      ),
  ];
  final p = _parenGroupRegex.allMatches(b.maskedSlice).toList();
  if (p.length >= 3) {
    out.add(
      idx.by(
        b.startOffset + p[2].start,
        p.length >= 4,
        'block-paren-pileup: ${p.length} parens in block',
      ),
    );
  }
  return out;
}

List<ProseSmell> _emDashSmells(
  _LineIndex idx,
  int base,
  String s,
  SmellSeverity single,
) {
  final f = s.indexOf('\u2014');
  if (f < 0) return const [];
  if (s.indexOf('\u2014', f + 1) >= 0) {
    return [idx.hi(base + f, 'paired-em-dash: Paired em-dash aside', '\u2014')];
  }
  return [idx.mark(base + f, single, 'prose-em-dash: Prose em-dash', '\u2014')];
}

(int, List<ProseSmell>) _analyzeSentence(
  _MaskedDoc m,
  (int, String, int, int, bool) s,
) {
  final idx = m.lineIndex;
  final (pw, pSm) = _checkSentenceParens(idx, s);
  return (
    pw,
    [
      ..._checkFlow(idx, s),
      ..._slashSmells(idx, s),
      ..._tildeSmells(idx, s),
      ...pSm,
    ],
  );
}

List<ProseSmell> _checkFlow(_LineIndex idx, (int, String, int, int, bool) s) {
  final semi = _semiSmell(idx, s.$1, s.$2, s.$3);
  return [
    if (s.$3 > 25 && s.$4 >= 7)
      idx.by(s.$1, s.$4 >= 9, 'code-pill-soup: ${s.$4} code spans in ${s.$3}w'),
    if (s.$3 > 35)
      idx.by(s.$1, s.$3 >= 45, 'long-sentence: ${s.$3}-word sentence'),
    ?semi,
  ];
}

ProseSmell? _semiSmell(_LineIndex idx, int off, String txt, int words) {
  final u = Uint16List.fromList(txt.codeUnits);
  _maskRegexMatches(u, _htmlEntityRegex);
  _maskRegexMatches(u, _parenGroupRegex);
  final clean = String.fromCharCodes(u);
  final f = clean.indexOf(';');
  if (f < 0) return null;
  final n = ';'.allMatches(clean).length;
  return idx.by(
    off + f,
    n >= 2 || words > 35,
    'prose-semicolon-chain: $n semicolon(s)',
    ';',
  );
}

List<ProseSmell> _slashSmells(_LineIndex idx, (int, String, int, int, bool) s) {
  final u = Uint16List.fromList(s.$2.codeUnits);
  _maskRegexMatches(u, _domainOrRepoPathRegex);
  _maskRegexMatches(u, _codeSlashChainRegex);
  final clean = String.fromCharCodes(u), out = <ProseSmell>[];
  for (final m in _slash3ChainRegex.allMatches(clean)) {
    final t = m[0]!;
    if (!_allowedSlash3.contains(t.toLowerCase()) &&
        !t.contains(_codeSentinelChar)) {
      out.add(
        idx.hi(s.$1 + m.start, 'slash-jargon-chain: 3+ term slash chain', t),
      );
    }
  }
  final pairs = [
    for (final m in _slashPairRegex.allMatches(clean))
      if (!m[0]!.contains(_codeSentinelChar)) m,
  ];
  if (pairs.length >= 3) {
    out.add(
      idx.sm(
        s.$1 + pairs.first.start,
        'slash-jargon-chain: ${pairs.length} slash pairs',
        pairs.first[0]!,
      ),
    );
  }
  return out;
}

List<ProseSmell> _tildeSmells(
  _LineIndex idx,
  (int, String, int, int, bool) s,
) => [
  for (final m in _tildePctRangeRegex.allMatches(s.$2))
    idx.by(
      s.$1 + m.start,
      !s.$5,
      'uncited-tilde-range: Tilde range',
      idx.spanEx(s.$1 + m.start, m.end - m.start),
    ),
];

(int, List<ProseSmell>) _checkSentenceParens(
  _LineIndex idx,
  (int, String, int, int, bool) s,
) {
  final (target, base) = _unwrapStandaloneParen(s.$2, s.$1);
  final ms = _parenGroupRegex.allMatches(target).toList();
  final ws = [for (final m in ms) _countWords(m[1]!)];
  final sum = ws.fold<int>(0, (a, b) => a + b), out = <ProseSmell>[];
  if (ms.length >= 3 || (ms.length == 2 && sum >= 6)) {
    out.add(
      idx.by(
        s.$1,
        ms.length >= 3 || sum >= 10,
        'multi-paren-sentence: ${ms.length} parens (${sum}w)',
      ),
    );
  }
  for (var i = 0; i < ms.length; i++) {
    final m = ms[i],
        off = base + m.start,
        ex = idx.spanEx(off, m.end - m.start);
    out
      ..addAll(_citeParenSmells(idx, off, (m[1]!, ws[i], ex)))
      ..addAll(_clauseParenSmells(idx, off, (m[1]!, ws[i], ex)));
  }
  return (sum, out);
}

List<ProseSmell> _citeParenSmells(
  _LineIndex idx,
  int off,
  (String, int, String) p,
) {
  final (txt, pw, ex) = p;
  final links = _linkSentinelChar.allMatches(txt).length;
  if (txt.contains(';') ||
      links >= 2 ||
      (','.allMatches(txt).length >= 3 && pw > 6)) {
    return [idx.hi(off, 'compound-citation-paren: Compound paren', ex)];
  }
  final sm = _seeParenRegex.firstMatch('($txt)');
  if (sm == null) return const [];
  final hi = links > 0 || _domainOrRepoPathRegex.hasMatch(sm[1]!) || pw > 4;
  return [idx.by(off, hi, 'compound-citation-paren: "(see ...)" crutch', ex)];
}

List<ProseSmell> _clauseParenSmells(
  _LineIndex idx,
  int off,
  (String, int, String) p,
) {
  final (txt, pw, ex) = p;
  final cl =
      (pw >= 6 && _subordinateOpenRegex.hasMatch(txt)) ||
      (pw > 6 && _clauseVerbRegex.hasMatch(txt));
  if (pw > 10 || cl) {
    return [idx.hi(off, 'long-or-clause-paren: Clause in paren (${pw}w)', ex)];
  }
  return pw >= 8
      ? [idx.sm(off, 'long-or-clause-paren: Long paren (${pw}w)', ex)]
      : const [];
}

(String, int) _unwrapStandaloneParen(String text, int start) {
  if (!text.startsWith('(') || !text.endsWith(')')) return (text, start);
  var d = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x28) d++;
    if (text.codeUnitAt(i) == 0x29 && --d == 0 && i < text.length - 1) {
      return (text, start);
    }
  }
  return d == 0
      ? (text.substring(1, text.length - 1), start + 1)
      : (text, start);
}

List<ProseSmell> _checkTableCells(_ExtractedDoc doc) => [
  for (final (off, cw, ex) in [for (final t in doc.tables) ...t.$5])
    if (cw > 30)
      doc.mask.lineIndex.by(
        off,
        cw > 35,
        'bloated-table-cell: ${cw}w table cell',
        ex,
      ),
];

List<ProseSmell> _checkMicroTables(_ExtractedDoc doc) {
  final m = [
    for (final t in doc.tables)
      if (!t.$4 && t.$2 <= 2 && t.$3 <= 2) t,
  ];
  if (m.isEmpty || (m.length == 1 && doc.profile == ProseProfile.readme)) {
    return const [];
  }
  return [
    doc.mask.lineIndex.by(
      m.first.$1,
      m.length >= 2,
      'micro-table-fragmentation: Micro-table',
      'table',
    ),
  ];
}

List<ProseSmell> _checkDocAggregates(_ExtractedDoc doc, ProseStats st) {
  final idx = doc.mask.lineIndex;
  final nBlocks = doc.blocks.where((b) => !b.isHeading).length;
  return [
    if (st.proseWords >= 300) ..._checkWord300Smells(idx, doc.profile, st),
    if (st.proseWords >= 400 && st.pctWordsInParens >= 7.5)
      idx.by(
        0,
        st.pctWordsInParens >= 12,
        'paren-word-share: ${st.pctWordsInParens}% in parens',
        'doc',
      ),
    if (st.proseWords >= 400 &&
        nBlocks >= 12 &&
        (st.boldLeadPct >= 55 || st.maxConsecutiveBoldLeads >= 15))
      idx.by(
        0,
        st.boldLeadPct >= 70 || st.maxConsecutiveBoldLeads >= 15,
        'wall-of-bold: ${st.boldLeadPct}% bold leads',
        'doc',
      ),
  ];
}

List<ProseSmell> _checkWord300Smells(
  _LineIndex idx,
  ProseProfile p,
  ProseStats st,
) {
  final (wCap, hCap) = switch (p) {
    ProseProfile.narrative => (6.0, 8.0),
    ProseProfile.readme => (22.0, 25.0),
    ProseProfile.auto ||
    ProseProfile.technical ||
    ProseProfile.spec => (15.0, 18.0),
  };
  return [
    if (st.pctOver30Words > 12 || st.sentenceMeanWords > 22)
      idx.by(
        0,
        st.pctOver30Words > 15 || st.sentenceMeanWords > 24,
        'run-on-share: ${st.pctOver30Words}% >30w',
        'doc',
      ),
    if (st.pillsPer100Words > wCap)
      idx.by(
        0,
        st.pillsPer100Words > hCap,
        'doc-pill-density: ${st.pillsPer100Words}/100w',
        'doc',
      ),
  ];
}
