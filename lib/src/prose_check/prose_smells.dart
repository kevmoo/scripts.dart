part of '../prose_check.dart';

final _nestedParenRegex = RegExp(
  r'\([^()]*\([^()]*\)[^()]*\)|\u2014[^\u2014]*\([^()]*\)[^\u2014]*\u2014',
);
final _seeParenRegex = RegExp(
  r'^\(\s*(?:see|cf\.?)\b([^()]*)\)$',
  caseSensitive: false,
);
final _subordinateOpenWords =
    'which,where,while,because,although,unless,whereas'.split(',').toSet();
final _clauseVerbWords =
    'is,are,was,were,has,have,had,does,did,can,could,will,would,should,must,'
            'fell,grew,dropped,inflated,revealed,preventing,excluding,'
            'requiring,keeping,causing,succeeding,resolving,overriding,'
            'meaning,forcing,leaving,declares,requires,allows,ensures,tracks,'
            'writes,reads,produces,causes'
        .split(',')
        .toSet();
final _repoRootDirs =
    'lib,bin,test,tool,pkg,packages,docs,skills,scripts,web,example,src,'
            'references'
        .split(',')
        .toSet();
final _filePathExts = 'dart,py,go,js,ts,md,txt,yaml,yml,json,cc,h,sh,sql'
    .split(',')
    .toSet();
final _linkSlugLabelRegex = RegExp(r'\uE001[^\s,;:()]+');
final _codeSlashChainRegex = RegExp(r'\uE000(?:\s*/\s*\uE000)+');
final _slash3ChainRegex = RegExp(
  r'\b[A-Za-z0-9+#_\uE002-]{2,}/[A-Za-z0-9+#_.\uE002-]{2,}/'
  r'[A-Za-z0-9+#_.\uE002-]{2,}(?:/[A-Za-z0-9+#_.\uE002-]{2,})*\b',
);
final _slashPairRegex = RegExp(
  r'\b[A-Za-z0-9+#_.\uE002-]{2,}\s*/\s*[A-Za-z0-9+#_.\uE002-]{2,}\b',
);
final _tildePctRangeRegex = RegExp(
  r'(?:\b(?:illustrative|hypothetical|rough|guessed)\s+)?'
  r'~\s*\d+(?:\.\d+)?%?\s*(?:to|-|\u2013)\s*~?\d+(?:\.\d+)?%'
  r'|\b(?:illustrative|hypothetical|rough|guessed)\s+~?\d+(?:\.\d+)?%',
  caseSensitive: false,
);
final _htmlEntityRegex = RegExp(r'&[A-Za-z0-9#]+;');
final _allowedSlash3 =
    'html/css/js,html/css/svg/js,ci/cd/ct,r/w/x,yyyy/mm/dd,mm/dd/yyyy'
        .split(',')
        .toSet();
final _orgRepoSlugRegex = RegExp(r'^[a-z0-9_]+/[a-z0-9_]+-[a-z0-9_.-]+$');
final _listLeadTrimRegex = RegExp(r'^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?');
final _docNavRefRegex = RegExp(
  r'^\s*\uE001?\s*(?:tab|section|appendix|part|table|figure)\b',
  caseSensitive: false,
);
final _rawCodeSymbolRegex = RegExp(
  r'\bpackage:[a-z][a-z0-9_\uE002]*\b'
  r'|\b[a-z][a-z0-9]*(?:\uE002?_[a-z0-9]+)+\b'
  r'|\b[A-Za-z0-9_\uE002-]+\.(?:dart|h|cc|cpp|hpp|py|go|rs|kt|java|swift|proto|yaml|json|toml|sh)\b'
  r'|(?:(?<=\s)|^)--[a-z][a-z0-9-]+\b',
);

ProseCheckReport _evaluateSmells(
  _ExtractedDoc doc, {
  required String path,
  required String reason,
  Directory? baseDir,
}) {
  final (stats, boldOff, sentSmells) = _computeProseStats(doc);
  final smells = <ProseSmell>[
    ..._checkLinkSmells(doc.mask, baseDir),
    ..._checkInlineCodeSmells(doc.mask, doc.profile),
    ..._checkBlockAndHeadingSmells(doc),
    ...sentSmells,
    ..._checkTableCells(doc),
    ..._checkWideTables(doc),
    ..._checkMicroTables(doc),
    ..._checkDocAggregates(doc, stats, boldOff),
  ]..sort(_compareSmells);
  final counts = <String, int>{};
  for (final s in smells) {
    counts[s.smellId] = (counts[s.smellId] ?? 0) + 1;
  }
  return ProseCheckReport(
    path: path,
    profile: doc.profile,
    profileReason: reason,
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

(ProseStats, int, List<ProseSmell>) _computeProseStats(_ExtractedDoc doc) {
  final proseBlocks = [
    for (final b in doc.blocks)
      if (!b.isHeading) b,
  ];
  final (labeled, maxRun, boldOff) = _countBoldLeads(proseBlocks);
  final (sentWords, parenW, pills, rawSyms, sentSmells) = _scanBlockSentences(
    doc,
    proseBlocks,
  );
  final sorted = List.of(sentWords)..sort();
  final sc = sorted.length, totalW = sorted.fold<int>(0, (a, b) => a + b);
  final cells = [for (final t in doc.tables) ...t.$5];
  final maxCell = cells.fold<int>(0, (m, c) => math.max(m, c.$2));
  final maxCols = doc.tables.fold<int>(0, (m, t) => math.max(m, t.$2));
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
      proseBlocks.length,
      maxCols,
      _pct(rawSyms, totalW),
    ),
    boldOff,
    sentSmells,
  );
}

(List<int>, int, int, int, List<ProseSmell>) _scanBlockSentences(
  _ExtractedDoc doc,
  List<_ProseBlock> blocks,
) {
  final words = <int>[], smells = <ProseSmell>[];
  var parenW = 0, pills = 0, rawSyms = 0;
  for (final blk in blocks) {
    if (blk.maskedSlice.contains(_codeSentinelChar)) {
      pills += _codeSentinelChar.allMatches(blk.maskedSlice).length;
    }
    final (mpw, mSm) = _multiSentParenSmells(doc.mask.lineIndex, blk);
    parenW += mpw;
    smells.addAll(mSm);
    for (final s in blk.sentences) {
      words.add(s.$3);
      final (pw, rs, sm) = _analyzeSentence(doc, s);
      parenW += pw;
      rawSyms += rs;
      smells.addAll(sm);
    }
  }
  return (words, parenW, pills, rawSyms, smells);
}

(int, List<ProseSmell>) _multiSentParenSmells(_LineIndex idx, _ProseBlock b) {
  if (b.sentences.length < 2 || !b.maskedSlice.contains('(')) {
    return (0, const []);
  }
  final base = b.startOffset + b.bodyRelOffset;
  final body = b.maskedSlice.substring(b.bodyRelOffset);
  var sum = 0;
  final out = <ProseSmell>[];
  for (final (ps, pe, txt) in _innermostParens(body)) {
    final s = base + ps, e = base + pe;
    if (b.sentences.any((x) => s >= x.$1 && e <= x.$1 + x.$2.length)) continue;
    final pw = _countWords(txt);
    sum += pw;
    if (pw >= 6) {
      out.add(
        idx.by(
          s,
          pw > 10 || _hasClauseWord(txt, true),
          'long-or-clause-paren: Multi-sentence paren (${pw}w)',
          idx.spanEx(s, pe - ps),
        ),
      );
    }
  }
  return (sum, out);
}

(int, int, int) _countBoldLeads(List<_ProseBlock> blocks) {
  var labeled = 0, run = 0, maxRun = 0, runStart = 0, maxRunOff = 0;
  for (final b in blocks) {
    if (!b.hasBoldOrItalicLead) {
      run = 0;
    } else {
      labeled++;
      if (run++ == 0) runStart = b.startOffset;
      if (run > maxRun) (maxRun, maxRunOff) = (run, runStart);
    }
  }
  return (labeled, maxRun, maxRunOff);
}

String _normLeadKey(String raw, _ProseBlock b) => _clipEx(
  raw.substring(b.startOffset, b.startOffset + b.bodyRelOffset),
  80,
).replaceFirst(_listLeadTrimRegex, '').toLowerCase();

Map<String, int> _countLeadParenKeys(_ExtractedDoc doc) {
  final counts = <String, int>{};
  for (final b in doc.blocks) {
    if (!b.isHeading && b.leadOpenParenOffset != null) {
      final k = _normLeadKey(doc.mask.raw, b);
      counts[k] = (counts[k] ?? 0) + 1;
    }
  }
  return counts;
}

ProseSmell? _leadParenSmell(
  _LineIndex idx,
  _ProseBlock b,
  Map<String, int> counts,
  Set<String> seen,
) {
  final off = b.leadOpenParenOffset;
  if (off == null) return null;
  final k = _normLeadKey(idx.raw, b), n = counts[k] ?? 1;
  if (n < 3) return idx.hi(off, 'bold-lead-paren: Paren in bullet lead');
  return seen.add(k)
      ? idx.sm(off, 'bold-lead-paren: Repeated schema lead (${n}x)')
      : null;
}

List<ProseSmell> _checkBlockAndHeadingSmells(_ExtractedDoc doc) {
  final em = doc.profile == ProseProfile.readme
      ? SmellSeverity.info
      : SmellSeverity.smell;
  final leadCounts = _countLeadParenKeys(doc), seenLeads = <String>{};
  return [
    for (final b in doc.blocks)
      ...(b.isHeading
          ? _headingSmells(doc.mask.lineIndex, b, em)
          : _blockSmells(doc.mask.lineIndex, b, em, leadCounts, seenLeads)),
  ];
}

List<(int, int, String)> _innermostParens(String s) {
  final out = <(int, int, String)>[];
  var open = -1;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x28) {
      open = i;
    } else if (c == 0x29 && open >= 0) {
      out.add((open, i + 1, s.substring(open + 1, i)));
      open = -1;
    }
  }
  return out;
}

List<ProseSmell> _headingSmells(
  _LineIndex idx,
  _ProseBlock b,
  SmellSeverity em,
) {
  final out = _emDashSmells(idx, b.startOffset, b.maskedSlice, em);
  if (b.headingLevel < 2 || !b.maskedSlice.contains('(')) return out;
  final p = _innermostParens(b.maskedSlice);
  if (p.length >= 2) {
    final pw = p.fold<int>(0, (sum, m) => sum + _countWords(m.$3));
    return [
      ...out,
      idx.by(
        b.startOffset + p.first.$1,
        p.length >= 3 || pw >= 10,
        'multi-paren-sentence: ${p.length} parens in heading (${pw}w)',
      ),
    ];
  }
  if (p.length == 1 && _countWords(p.first.$3) > 6) {
    return [
      ...out,
      idx.sm(
        b.startOffset + p.first.$1,
        'long-or-clause-paren: Heading paren >6w',
      ),
    ];
  }
  return out;
}

List<ProseSmell> _blockSmells(
  _LineIndex idx,
  _ProseBlock b,
  SmellSeverity em,
  Map<String, int> leadCounts,
  Set<String> seenLeads,
) {
  final leadSm = _leadParenSmell(idx, b, leadCounts, seenLeads);
  final out = <ProseSmell>[
    ?leadSm,
    ..._emDashSmells(
      idx,
      b.startOffset + b.bodyRelOffset,
      b.maskedSlice.substring(b.bodyRelOffset),
      em,
    ),
  ];
  if (!b.maskedSlice.contains('(')) return out;
  out.addAll(_nestedSmells(idx, b));
  final p = _innermostParens(b.maskedSlice);
  if (p.length >= 3) {
    out.add(
      idx.by(
        b.startOffset + p[2].$1,
        p.length >= 4,
        'block-paren-pileup: ${p.length} parens in block',
      ),
    );
  }
  return out;
}

List<ProseSmell> _nestedSmells(_LineIndex idx, _ProseBlock b) {
  if (!b.maskedSlice.contains('\u2014') && !_hasNestedParen(b.maskedSlice)) {
    return const [];
  }
  return [
    for (final m in _nestedParenRegex.allMatches(b.maskedSlice))
      idx.hi(
        b.startOffset + m.start,
        'nested-parens: Nested parens in prose',
        idx.spanEx(b.startOffset + m.start, m.end - m.start),
      ),
  ];
}

bool _hasNestedParen(String s) {
  var d = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x28 && ++d >= 2) return true;
    if (c == 0x29 && d > 0) d--;
  }
  return false;
}

List<ProseSmell> _emDashSmells(
  _LineIndex idx,
  int base,
  String s,
  SmellSeverity single,
) {
  final f = s.indexOf('\u2014');
  if (f < 0) return const [];
  final at = base + f, ex = idx.contextEx(at);
  if (s.indexOf('\u2014', f + 1) >= 0) {
    return [idx.hi(at, 'paired-em-dash: Paired em-dash aside', ex)];
  }
  return [idx.mark(at, single, 'prose-em-dash: Prose em-dash', ex)];
}

bool _isReaderProseProfile(ProseProfile p) =>
    p == ProseProfile.narrative || p == ProseProfile.spec;

(int, int, List<ProseSmell>) _analyzeSentence(
  _ExtractedDoc doc,
  (int, String, int, int, bool) s,
) {
  final idx = doc.mask.lineIndex;
  final (pw, pSm) = _checkSentenceParens(doc, s);
  final rawSyms = _rawCodeSymbolRegex.allMatches(s.$2).length;
  return (
    pw,
    rawSyms,
    [
      ..._checkFlow(idx, doc.profile, s, rawSyms),
      ..._slashSmells(idx, s),
      ..._tildeSmells(idx, s),
      ...pSm,
    ],
  );
}

List<ProseSmell> _checkFlow(
  _LineIndex idx,
  ProseProfile prof,
  (int, String, int, int, bool) s,
  int rawSyms,
) {
  final semi = _semiSmell(idx, s.$1, s.$2, s.$3);
  final rawSoup = _isReaderProseProfile(prof) && s.$3 >= 12 && rawSyms >= 4;
  return [
    if (s.$3 > 25 && s.$4 >= 7)
      idx.by(s.$1, s.$4 >= 9, 'code-pill-soup: ${s.$4} code spans in ${s.$3}w'),
    if (rawSoup)
      idx.by(
        s.$1,
        rawSyms >= 6,
        'raw-symbol-soup: $rawSyms unbackticked code symbols in ${s.$3}w',
      ),
    if (s.$3 > 35)
      idx.by(s.$1, s.$3 >= 45, 'long-sentence: ${s.$3}-word sentence'),
    ?semi,
  ];
}

ProseSmell? _semiSmell(_LineIndex idx, int off, String txt, int words) {
  if (!txt.contains(';')) return null;
  final u = Uint16List.fromList(txt.codeUnits);
  if (txt.contains('&')) _maskRegexMatches(u, _htmlEntityRegex);
  if (txt.contains('(')) {
    for (final (ps, pe, _) in _innermostParens(txt)) {
      _fillSpaces(u, ps, pe);
    }
  }
  final clean = String.fromCharCodes(u), f = clean.indexOf(';');
  if (f < 0) return null;
  final n = ';'.allMatches(clean).length;
  if (n == 1 && words <= 28) return null;
  final at = off + f,
      label = n == 1 ? '1 semicolon (${words}w)' : '$n semicolons';
  return idx.by(
    at,
    n >= 2 || words > 35,
    'prose-semicolon-chain: $label',
    idx.contextEx(at),
  );
}

List<ProseSmell> _slashSmells(_LineIndex idx, (int, String, int, int, bool) s) {
  final firstSlash = s.$2.indexOf('/');
  if (firstSlash < 0 || firstSlash == s.$2.lastIndexOf('/')) return const [];
  final u = Uint16List.fromList(s.$2.codeUnits);
  if (s.$5) _maskRegexMatches(u, _linkSlugLabelRegex);
  _maskDomainOrRepoPaths(u);
  if (s.$4 >= 2) _maskRegexMatches(u, _codeSlashChainRegex);
  final rem = String.fromCharCodes(u), f2 = rem.indexOf('/');
  if (f2 < 0 || f2 == rem.lastIndexOf('/')) return const [];
  return [
    ..._collectSlash3Smells(idx, u, rem, s.$1),
    ?_slashPairSmell(idx, String.fromCharCodes(u), s.$1),
  ];
}

bool _startsCapOrDotCap(String s) =>
    s.isNotEmpty &&
    (_isUpper(s.codeUnitAt(0)) ||
        (s.codeUnitAt(0) == 0x2E && s.length > 1 && _isUpper(s.codeUnitAt(1))));

bool _isBenignSlashPair(String raw) {
  final p = raw.replaceAll('\uE002', '');
  if (!p.contains(' ') && _orgRepoSlugRegex.hasMatch(p)) return true;
  final sl = p.indexOf('/');
  return _startsCapOrDotCap(p.substring(0, sl).trim()) &&
      _startsCapOrDotCap(p.substring(sl + 1).trim());
}

ProseSmell? _slashPairSmell(_LineIndex idx, String clean, int base) {
  if (!clean.contains('/')) return null;
  final pairs = [
    for (final m in _slashPairRegex.allMatches(clean))
      if (!m[0]!.contains(_codeSentinelChar) && !_isBenignSlashPair(m[0]!)) m,
  ];
  if (pairs.length < 3) return null;
  final at = base + pairs.first.start;
  return idx.sm(
    at,
    'slash-jargon-chain: ${pairs.length} slash pairs',
    idx.contextEx(at),
  );
}

void _maskDomainOrRepoPaths(Uint16List u) {
  final s = String.fromCharCodes(u);
  for (var i = 0; i < s.length;) {
    if (!_isSlashTokenChar(s.codeUnitAt(i))) {
      i++;
      continue;
    }
    final end = _slashTokenEnd(s, i), te = _trimTrailingDots(s, i, end);
    if (_isDomainOrRepoSpan(s, i, te)) _fillSpaces(u, i, te);
    i = end;
  }
}

bool _hasDomainOrRepoPath(String s) {
  for (var i = 0; i < s.length;) {
    if (!_isSlashTokenChar(s.codeUnitAt(i))) {
      i++;
      continue;
    }
    final end = _slashTokenEnd(s, i);
    if (_isDomainOrRepoSpan(s, i, _trimTrailingDots(s, i, end))) return true;
    i = end;
  }
  return false;
}

bool _isSlashTokenChar(int c) =>
    _isWord(c) || c == 0x2E || c == 0x2F || c == 0x23 || c == 0x2D;

int _slashTokenEnd(String s, int i) {
  while (i < s.length && _isSlashTokenChar(s.codeUnitAt(i))) {
    i++;
  }
  return i;
}

int _trimTrailingDots(String s, int start, int end) {
  while (end > start && s.codeUnitAt(end - 1) == 0x2E) {
    end--;
  }
  return end;
}

bool _isDomainOrRepoSpan(String s, int ts, int te) {
  final tok = s.substring(ts, te);
  final okPre =
      ts == 0 || s.codeUnitAt(ts - 1) <= 0x20 || s.codeUnitAt(ts - 1) == 0x28;
  if (tok.startsWith('//')) return okPre && tok.length > 2;
  final slash = tok.indexOf('/');
  if (slash <= 0 || slash >= tok.length - 1) return false;
  final head = tok.substring(0, slash), tail = tok.substring(slash + 1);
  return _isDomainHost(head) ||
      (okPre && _repoRootDirs.contains(head)) ||
      _hasKnownFileExt(tok, slash) ||
      (_isLowerAlpha2To10(head) && _hasAsciiDigit(tail));
}

bool _isDomainHost(String h) =>
    h.length >= 4 && h.contains('.') && !h.startsWith('.') && !h.endsWith('.');

bool _hasKnownFileExt(String tok, int slash) {
  final dot = tok.lastIndexOf('.');
  return dot > slash && _filePathExts.contains(tok.substring(dot + 1));
}

bool _isLowerAlpha2To10(String h) {
  if (h.length < 2 || h.length > 10) return false;
  for (var i = 0; i < h.length; i++) {
    final c = h.codeUnitAt(i);
    if (c < 0x61 || c > 0x7A) return false;
  }
  return true;
}

List<ProseSmell> _collectSlash3Smells(
  _LineIndex idx,
  Uint16List u,
  String rem,
  int base,
) {
  final out = <ProseSmell>[];
  for (final m in _slash3ChainRegex.allMatches(rem)) {
    final t = m[0]!.replaceAll('\uE002', '');
    if (!_allowedSlash3.contains(t.toLowerCase()) &&
        !t.contains(_codeSentinelChar)) {
      out.add(
        idx.hi(base + m.start, 'slash-jargon-chain: 3+ term slash chain', t),
      );
    }
    _fillSpaces(u, m.start, m.end);
  }
  return out;
}

List<ProseSmell> _tildeSmells(_LineIndex idx, (int, String, int, int, bool) s) {
  if (!s.$2.contains('~')) return const [];
  return [
    for (final m in _tildePctRangeRegex.allMatches(s.$2))
      idx.by(
        s.$1 + m.start,
        !s.$5,
        'uncited-tilde-range: Tilde range',
        idx.spanEx(s.$1 + m.start, m.end - m.start),
      ),
  ];
}

(int, List<ProseSmell>) _checkSentenceParens(
  _ExtractedDoc doc,
  (int, String, int, int, bool) s,
) {
  if (!s.$2.contains('(')) return (0, const []);
  final idx = doc.mask.lineIndex;
  final (target, base) = _unwrapStandaloneParen(s.$2, s.$1);
  final ms = _innermostParens(target);
  final ws = [for (final m in ms) _countWords(m.$3)];
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
    final m = ms[i], off = base + m.$1, ex = idx.spanEx(off, m.$2 - m.$1);
    out
      ..addAll(_citeParenSmells(doc, off, (m.$3, ws[i], ex)))
      ..addAll(_clauseParenSmells(idx, off, (m.$3, ws[i], ex)));
  }
  return (sum, out);
}

List<ProseSmell> _citeParenSmells(
  _ExtractedDoc doc,
  int off,
  (String, int, String) p,
) {
  final idx = doc.mask.lineIndex;
  final (txt, pw, ex) = p;
  final links = txt.contains(_linkSentinelChar)
      ? _linkSentinelChar.allMatches(txt).length
      : 0;
  final readmeTuple =
      doc.profile == ProseProfile.readme &&
      txt.contains(_codeSentinelChar) &&
      txt.contains('default');
  if (!readmeTuple && _isCompoundParen(txt, links, pw)) {
    return [idx.hi(off, 'compound-citation-paren: Compound paren', ex)];
  }
  if (!_startsSeeOrCf(txt)) return const [];
  final sm = _seeParenRegex.firstMatch('($txt)');
  if (sm == null) return const [];
  final target = sm[1]!;
  final nav = links <= 1 && _docNavRefRegex.hasMatch(target);
  final hi = !nav && (_hasDomainOrRepoPath(target) || links >= 2 || pw > 6);
  return [idx.by(off, hi, 'compound-citation-paren: "(see ...)" crutch', ex)];
}

bool _startsSeeOrCf(String txt) {
  final t = txt.trimLeft();
  if (t.length < 2) return false;
  final c0 = t.codeUnitAt(0) | 0x20, c1 = t.codeUnitAt(1) | 0x20;
  return (c0 == 0x73 && c1 == 0x65) || (c0 == 0x63 && c1 == 0x66);
}

bool _isCompoundParen(String txt, int links, int pw) =>
    txt.contains(';') ||
    links >= 2 ||
    (pw > 6 && txt.contains(',') && ','.allMatches(txt).length >= 3);

List<ProseSmell> _clauseParenSmells(
  _LineIndex idx,
  int off,
  (String, int, String) p,
) {
  final (txt, pw, ex) = p;
  if (pw < 6) return const [];
  if (pw > 10 || _hasClauseWord(txt, pw > 6)) {
    return [idx.hi(off, 'long-or-clause-paren: Clause in paren (${pw}w)', ex)];
  }
  return pw >= 8
      ? [idx.sm(off, 'long-or-clause-paren: Long paren (${pw}w)', ex)]
      : const [];
}

bool _hasClauseWord(String txt, bool checkVerbs) {
  final lc = txt.toLowerCase();
  for (var i = 0; i < lc.length;) {
    if (!_isLower(lc.codeUnitAt(i))) {
      i++;
      continue;
    }
    final end = _lowerRunEnd(lc, i), w = lc.substring(i, end);
    if (_subordinateOpenWords.contains(w) ||
        (checkVerbs && _clauseVerbWords.contains(w))) {
      return true;
    }
    i = end;
  }
  return false;
}

int _lowerRunEnd(String s, int i) {
  while (i < s.length && _isLower(s.codeUnitAt(i))) {
    i++;
  }
  return i;
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

List<ProseSmell> _checkWideTables(_ExtractedDoc doc) => [
  for (final (off, cols, rows, meta, _) in doc.tables)
    if (!meta && cols >= 6)
      doc.mask.lineIndex.by(
        off,
        cols >= 8,
        'wide-table: $cols-column table ($rows rows)',
        doc.mask.lineIndex.spanEx(off),
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
  final off = m.first.$1;
  return [
    doc.mask.lineIndex.by(
      off,
      m.length >= 2,
      'micro-table-fragmentation: Micro-table',
      doc.mask.lineIndex.spanEx(off),
    ),
  ];
}

List<ProseSmell> _checkDocAggregates(
  _ExtractedDoc doc,
  ProseStats st,
  int boldOff,
) {
  final idx = doc.mask.lineIndex, c = _capsFor(doc.profile);
  final w400 = st.proseWords >= 400;
  return [
    if (st.proseWords >= 300) ..._checkWord300Smells(idx, doc.profile, c, st),
    if (w400 && st.pctWordsInParens >= c.parenWarn)
      idx.by(
        0,
        st.pctWordsInParens >= c.parenHigh,
        'paren-word-share: ${st.pctWordsInParens}% in parens',
        '${st.proseWords} prose words',
      ),
    if (w400 &&
        st.proseBlocks >= 12 &&
        (st.boldLeadPct >= c.boldWarn ||
            st.maxConsecutiveBoldLeads >= c.boldRunHigh))
      idx.by(
        boldOff,
        st.boldLeadPct >= c.boldHigh ||
            st.maxConsecutiveBoldLeads >= c.boldRunHigh,
        'wall-of-bold: ${st.boldLeadPct}% of ${st.proseBlocks} blocks '
        '(run ${st.maxConsecutiveBoldLeads})',
        idx.spanEx(boldOff),
      ),
  ];
}

List<ProseSmell> _checkWord300Smells(
  _LineIndex idx,
  ProseProfile prof,
  _ProfileCaps c,
  ProseStats st,
) {
  final rawCap = prof == ProseProfile.narrative ? (2.0, 4.0) : (3.5, 6.0);
  return [
    if (st.pctOver30Words > c.over30Warn || st.sentenceMeanWords > c.meanWarn)
      idx.by(
        0,
        st.pctOver30Words > c.over30High || st.sentenceMeanWords > c.meanHigh,
        'run-on-share: ${st.pctOver30Words}% >30w',
        'mean ${st.sentenceMeanWords}w, max ${st.sentenceMaxWords}w',
      ),
    if (st.pillsPer100Words > c.pillsWarn)
      idx.by(
        0,
        st.pillsPer100Words > c.pillsHigh,
        'doc-pill-density: ${st.pillsPer100Words}/100w',
        '${st.proseWords} prose words',
      ),
    if (_isReaderProseProfile(prof) && st.rawSymbolsPer100Words > rawCap.$1)
      idx.by(
        0,
        st.rawSymbolsPer100Words > rawCap.$2,
        'raw-symbol-density: ${st.rawSymbolsPer100Words}/100w unbackticked',
        '${st.proseWords} prose words',
      ),
  ];
}
