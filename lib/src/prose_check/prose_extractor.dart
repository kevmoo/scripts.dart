part of '../prose_check.dart';

final _taskMarkerRegex = RegExp(r'^\[[ xX]\]\s+');
final _leadingLabelRegex = RegExp(
  r'^(?:\*\*([^*]+)\*\*\s*:?|\*([^*]+)\*\s*:)\s*',
);
final _metaHeaderLineRegex = RegExp(
  r'^(?:\*?[A-Za-z]+(?: [A-Za-z]+)?:\*?[ \t]+\S+[ \t]*){2,}$',
);
final _alertHeaderRegex = RegExp(
  r'^>\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$',
);
final _hrLineRegex = RegExp(r'^[-*_]{3,}\s*$');
final _headingPrefixRegex = RegExp(r'^(#{1,6})\s+');
final _tableSepCellRegex = RegExp(r'^:?-{2,}:?$');
final _mdKeyStripRegex = RegExp(r'[*_`]');
final _enumParenRegex = RegExp(r'\(\s*(?:\d{1,2}|[a-z]|[ivx]{1,4})\s*\)');
final _footnoteRefRegex = RegExp(r'\[\^[^\]]+\]');

final _sentenceBoundaryRegex = RegExp(
  r'[.!?](?:["\x27\u201d\u2019)\]*]+)?(?:\[\^[^\]]+\])*(?=\s+|$)',
);
final _tier1Abbrevs =
    'vs,v,e.g,i.e,incl,approx,cf,al,viz,ca,mr,ms,mrs,dr,prof,st,fig,figs,no,'
            'p,pp'
        .split(',')
        .toSet();
final _tier2Abbrevs = 'etc,Inc,Corp,Ltd,Co,Jr,Sr'.split(',').toSet();
final _initialStarters =
    'However,Therefore,Thus,The,This,That,In,On,At,For,When,While,If,We,It,'
            'They,Our'
        .split(',')
        .toSet();
final _etcStarters = {
  ..._initialStarters,
  ...'Moreover,Furthermore,Instead,Meanwhile,Next,First,Second,Third,Finally,'
          'These,Those,Where,Because,Although'
      .split(','),
};
final _dotExts =
    'dev,com,org,io,net,gov,edu,uk,md,txt,py,go,js,ts,sql,pbtxt,tf,html,yaml,'
            'yml,json,dart,cc,h,sh,toml,lock'
        .split(',')
        .toSet();
final _docMetadataKeys =
    'author,authors,status,owner,owners,updated,date,reviewers,target'
        .split(',')
        .toSet();

final class _ProseBlock {
  final int startOffset, headingLevel, bodyRelOffset;
  final String maskedSlice;
  final bool hasBoldOrItalicLead;
  final int? leadOpenParenOffset;
  final List<(int off, String text, int words, int pills, bool link)> sentences;

  const new(
    this.startOffset,
    this.maskedSlice, [
    this.headingLevel = 0,
    this.hasBoldOrItalicLead = false,
    this.leadOpenParenOffset,
    this.bodyRelOffset = 0,
    this.sentences = const [],
  ]);

  bool get isHeading => headingLevel > 0;
}

final class _ExtractedDoc {
  final _MaskedDoc mask;
  final ProseProfile profile;
  final ProseFormat format;
  final List<_ProseBlock> blocks;
  final List<(int off, int cols, int rows, bool meta, List<(int, int, String)>)>
  tables;
  const new(this.mask, this.profile, this.format, this.blocks, this.tables);
}

int _countWords(String text) {
  final s = text.contains('[^')
      ? text.replaceAll(_footnoteRefRegex, ' ')
      : text;
  var words = 0, i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c == _codeSentinel) {
      words++;
      i++;
    } else if (_isWordCore(c)) {
      words++;
      i = _consumeWordToken(s, i + 1);
    } else {
      i++;
    }
  }
  return words;
}

bool _isWordCore(int c) => _isWord(c) || c == _escapeJoiner;

int _consumeWordToken(String s, int start) {
  var i = start;
  while (i < s.length) {
    final nx = _stepWordToken(s, i);
    if (nx < 0) break;
    i = nx;
  }
  return i;
}

int _stepWordToken(String s, int i) {
  final c = s.codeUnitAt(i);
  if (_isWordCore(c) || c == 0x23) return i + 1;
  if (_isWordJoinPunct(c) &&
      i + 1 < s.length &&
      _isWordCore(s.codeUnitAt(i + 1))) {
    return i + 2;
  }
  return -1;
}

bool _isWordJoinPunct(int c) =>
    c == 0x2E || c == 0x2C || c == 0x27 || c == 0x2F || c == 0x2D;

_ExtractedDoc _extractDocument(_MaskedDoc m, ProseProfile p, ProseFormat f) {
  final st = _ExtractorState(m, p, f);
  final maxLn = m.activeEnd == 0
      ? 0
      : m.lineIndex.locationAt(m.activeEnd - 1).line;
  for (var ln = 1; ln <= maxLn; ln++) {
    st.consumeLine(ln);
  }
  st
    ..flushBlock()
    ..flushTable();
  return _ExtractedDoc(m, p, f, st.blocks, st.tables);
}

bool _isBlankRange(Uint16List u, int s, int e) {
  for (var i = s; i < e; i++) {
    if (u[i] > 0x20) return false;
  }
  return true;
}

final class _ExtractorState {
  final _MaskedDoc mask;
  final ProseProfile profile;
  final ProseFormat format;
  final Uint16List cleanUnits;
  final List<_ProseBlock> blocks = [];
  final List<(int, int, int, bool, List<(int, int, String)>)> tables = [];
  int? blockStart, tableOffset, tableCols;
  int blockEnd = 0, tableRowIndex = 0, tableBodyRows = 0;
  bool isBullet = false, inExemptQuote = false, prevQuoteColon = false;
  bool tableIsMeta = false;
  final List<(int, int, String)> tableCells = [];

  new(this.mask, this.profile, this.format)
    : cleanUnits = Uint16List.fromList(
        mask.masked
            .substring(
              0,
              mask.activeEnd == 0
                  ? 0
                  : mask.lineIndex
                        .lineRange(
                          mask.lineIndex.locationAt(mask.activeEnd - 1).line,
                        )
                        .$2,
            )
            .codeUnits,
      );

  void consumeLine(int ln) {
    final (s, e) = mask.lineIndex.lineRange(ln);
    if (_isBlankRange(cleanUnits, s, e)) {
      flushBlock();
      return flushTable();
    }
    final maskL = mask.masked.substring(s, e);
    final rawL = mask.raw.substring(s, e);
    if (format == ProseFormat.markdown && _consumeMd(ln, (s, e), rawL, maskL)) {
      return;
    }
    flushTable();
    final noCr = String.fromCharCodes(cleanUnits.sublist(s, e))
        .replaceAll('\r', '');
    final b = _mayStartList(noCr.trimLeft())
        ? _listItemIndentRegex.firstMatch(noCr)
        : null;
    if (b != null) {
      flushBlock();
      blockStart = s;
      blockEnd = e;
      isBullet = true;
      final rest = noCr.substring(b.end);
      final tm = rest.startsWith('[')
          ? _taskMarkerRegex.firstMatch(rest)
          : null;
      return _fillSpaces(cleanUnits, s, s + b.end + (tm?.end ?? 0));
    }
    blockStart ??= s;
    blockEnd = e;
  }

  bool _consumeMd(int ln, (int, int) r, String rawL, String maskL) {
    final strip = maskL.trim(), rawT = rawL.trim();
    if (_isFlushLine(strip, rawT)) {
      flushBlock();
      flushTable();
      return true;
    }
    if (strip.startsWith('|') && strip.endsWith('|')) {
      return _consumePipeLine(ln, r.$1, rawL, maskL);
    }
    final hm = strip.startsWith('#')
        ? _headingPrefixRegex.firstMatch(strip)
        : null;
    if (hm != null) {
      flushBlock();
      flushTable();
      _fillSpaces(cleanUnits, r.$1, r.$1 + maskL.indexOf('#') + hm.end);
      final slice = String.fromCharCodes(cleanUnits.sublist(r.$1, r.$2));
      blocks.add(_ProseBlock(r.$1, slice, hm[1]!.length));
      return true;
    }
    return _consumeQuoteState(r.$1, strip, rawT, maskL);
  }

  bool _consumeQuoteState(int s, String strip, String rawT, String maskL) {
    if (!strip.startsWith('>')) {
      inExemptQuote =
          rawT.startsWith('**Before') || rawT.startsWith('- **Before');
      prevQuoteColon = rawT.endsWith(':') && !rawT.startsWith('-');
      return false;
    }
    final qIdx = maskL.indexOf('>'), afterQ = maskL.substring(qIdx + 1).trim();
    if (_isExemptQuoteBody(afterQ)) {
      inExemptQuote = afterQ.isNotEmpty;
      flushBlock();
      return true;
    }
    _fillSpaces(cleanUnits, s, s + qIdx + 1);
    return false;
  }

  bool _isExemptQuoteBody(String q) =>
      inExemptQuote ||
      prevQuoteColon ||
      q.isEmpty ||
      q.startsWith('"') ||
      (q.startsWith('*') && !q.startsWith('**'));

  bool _consumePipeLine(int ln, int s, String rawL, String maskL) {
    final p1 = maskL.indexOf('|'), p2 = maskL.lastIndexOf('|');
    if (p2 <= p1) return true;
    final inS = p1 + 1, inMask = maskL.substring(inS, p2);
    final spans = _splitPipeOffsets(inMask);
    if (tableCols == null && spans.length == 1) {
      if (_isSepRow(inMask, spans)) {
        flushBlock();
        return true;
      }
      cleanUnits[s + p1] = 0x20;
      cleanUnits[s + p2] = 0x20;
      return false;
    }
    flushBlock();
    _consumeMultiColTableRow(ln, (s + p1, s + inS), (rawL, inMask, p2), spans);
    return true;
  }

  void _consumeMultiColTableRow(
    int ln,
    (int pipeOff, int innerOff) offs,
    (String rawL, String inMask, int p2) txt,
    List<(int, int)> spans,
  ) {
    final inS = offs.$2 - offs.$1 + txt.$1.indexOf('|');
    final inRaw = txt.$1.substring(inS, math.min(txt.$3, txt.$1.length));
    if (tableCols == null) _initTableHeader(ln, offs.$1, inRaw, spans);
    if (_isSepRow(txt.$2, spans) || (tableCols ?? 0) < 2) return;
    if (tableRowIndex++ > 0) _recordRowCells(offs.$2, txt.$2, inRaw, spans);
  }

  void _initTableHeader(int ln, int off, String inRaw, List<(int, int)> spans) {
    final end = spans.isEmpty ? 0 : math.min(spans.first.$2, inRaw.length);
    final first = spans.isEmpty ? '' : inRaw.substring(spans.first.$1, end);
    final key = first.replaceAll(_mdKeyStripRegex, '').trim().toLowerCase();
    tableOffset = off;
    tableCols = spans.length;
    tableIsMeta =
        ln <= 15 && spans.length == 2 && _docMetadataKeys.contains(key);
  }

  void _recordRowCells(int base, String inM, String inR, List<(int, int)> sp) {
    tableBodyRows++;
    for (final (cs, ce) in sp) {
      final txt = inM.substring(cs, ce), cw = _countWords(txt);
      final off = base + cs + (txt.length - txt.trimLeft().length);
      tableCells.add((
        off,
        cw,
        _clipEx(inR.substring(cs, math.min(ce, inR.length))),
      ));
    }
  }

  void flushBlock() {
    if (blockStart case final s?) {
      blockStart = null;
      final b = _buildBlock(cleanUnits, (s, blockEnd), isBullet, profile);
      isBullet = false;
      if (b != null) blocks.add(b);
    }
  }

  void flushTable() {
    if (tableCols case final c?) {
      tables.add((
        tableOffset!,
        c,
        tableBodyRows,
        tableIsMeta,
        List.of(tableCells),
      ));
      tableCols = null;
      tableRowIndex = tableBodyRows = 0;
      tableIsMeta = false;
      tableCells.clear();
    }
  }
}

bool _isFlushLine(String s, String rawT) =>
    (_isHrStart(s) && _hrLineRegex.hasMatch(s)) ||
    s == '[TOC]' ||
    (s.startsWith('>') && _alertHeaderRegex.hasMatch(s)) ||
    rawT.startsWith('![') ||
    (rawT.startsWith('[![') && _countWords(s) <= 6);

bool _isHrStart(String s) =>
    s.length >= 3 &&
    (s.startsWith('---') || s.startsWith('***') || s.startsWith('___'));

bool _isSepRow(String inner, List<(int, int)> spans) => spans.every((s) {
  final c = inner.substring(s.$1, s.$2).trim();
  return c.isEmpty || _tableSepCellRegex.hasMatch(c);
});

List<(int, int)> _splitPipeOffsets(String inner) {
  final out = <(int, int)>[];
  var last = 0;
  for (var i = inner.indexOf('|'); i >= 0; i = inner.indexOf('|', i + 1)) {
    if (i == 0 || inner.codeUnitAt(i - 1) != 0x5C) {
      out.add((last, i));
      last = i + 1;
    }
  }
  return out..add((last, inner.length));
}

_ProseBlock? _buildBlock(Uint16List u, (int, int) r, bool bul, ProseProfile p) {
  final sub = u.sublist(r.$1, r.$2);
  final raw = String.fromCharCodes(sub), trim = raw.trim();
  if (trim.isEmpty ||
      (trim.length <= 160 &&
          trim.contains(':') &&
          _metaHeaderLineRegex.hasMatch(trim))) {
    return null;
  }
  final (lead, pOff, bRel) = bul ? _parseLead(raw, r.$1, p) : (false, null, 0);
  if (raw.contains('(')) _maskTopLevelEnumParens(sub);
  final clean = String.fromCharCodes(sub);
  final rel = clean.substring(bRel).trim().isNotEmpty ? bRel : 0;
  final sents = _splitSents(clean.substring(rel), r.$1 + rel);
  return _ProseBlock(r.$1, clean, 0, lead, pOff, bRel, sents);
}

void _maskTopLevelEnumParens(Uint16List sub) {
  final s = String.fromCharCodes(sub);
  for (final m in _enumParenRegex.allMatches(s)) {
    final pre = s.substring(0, m.start);
    if ('('.allMatches(pre).length == ')'.allMatches(pre).length) {
      _fillSpaces(sub, m.start, m.end);
    }
  }
}

(bool, int?, int) _parseLead(String raw, int start, ProseProfile p) {
  final ws = raw.length - raw.trimLeft().length, after = raw.substring(ws);
  if (!after.startsWith('*')) return (false, null, 0);
  final m = _leadingLabelRegex.firstMatch(after);
  if (m == null) return (false, null, 0);
  final lbl = m[1] ?? m[2] ?? '';
  final pIdx = lbl.contains('(') ? lbl.indexOf('(') : lbl.indexOf(')');
  if (pIdx < 0 || _okReadmeLead(lbl, p)) return (true, null, ws + m.end);
  return (
    true,
    start + ws + (after.startsWith('**') ? 2 : 1) + pIdx,
    ws + m.end,
  );
}

bool _okReadmeLead(String lbl, ProseProfile p) =>
    p == ProseProfile.readme &&
    lbl.contains(_codeSentinelChar) &&
    _countWords(lbl.replaceAll(_codeSentinelChar, '')) <= 4;

List<(int, String, int, int, bool)> _splitSents(String slice, int base) {
  final u = _zeroNonBoundaryDots(slice);
  if (slice.contains('(')) _maskMidParenDots(u);
  final seg = String.fromCharCodes(u), out = <(int, String, int, int, bool)>[];
  var cur = 0;
  for (final m in _sentenceBoundaryRegex.allMatches(seg)) {
    _emitSent(out, slice, base, (cur, m.end));
    cur = m.end;
  }
  if (cur < slice.length) _emitSent(out, slice, base, (cur, slice.length));
  return out;
}

Uint16List _zeroNonBoundaryDots(String slice) {
  final u = Uint16List.fromList(slice.codeUnits);
  if (_hasDotLike(slice)) _applyDotMasks(u, slice);
  return u;
}

bool _hasDotLike(String s) => s.contains('.') || s.contains('\u2026');

void _applyDotMasks(Uint16List u, String s) {
  for (var i = 0; i < u.length; i++) {
    if (u[i] == 0x2026) u[i] = 0;
  }
  for (var d = s.indexOf('.'); d >= 0; d = s.indexOf('.', d + 1)) {
    if (d + 2 < s.length &&
        s.codeUnitAt(d + 1) == 0x2E &&
        s.codeUnitAt(d + 2) == 0x2E) {
      d = _zeroDotRun(u, s, d);
    } else if (_isNonSentenceDot(s, d)) {
      u[d] = 0;
    }
  }
}

int _zeroDotRun(Uint16List u, String s, int d) {
  while (d + 1 < s.length && s.codeUnitAt(d + 1) == 0x2E) {
    u[d++] = 0;
  }
  u[d] = 0;
  return d;
}

bool _isNonSentenceDot(String s, int d) =>
    _isDecimalDot(s, d) ||
    _isLeadingExtDot(s, d) ||
    _isChainExtDot(s, d) ||
    _isInlineListDot(s, d) ||
    _isAbbrevOrInitialDot(s, d);

bool _isDecimalDot(String s, int d) =>
    d > 0 &&
    d + 1 < s.length &&
    (s.codeUnitAt(d - 1) ^ 0x30) <= 9 &&
    (s.codeUnitAt(d + 1) ^ 0x30) <= 9;

bool _isLeadingExtDot(String s, int d) {
  if (d > 0 && !_isLeadExtPre(s.codeUnitAt(d - 1))) return false;
  final end = _identDashEnd(s, d + 1), len = end - (d + 1);
  return len >= 1 &&
      len <= 12 &&
      (end == s.length || !_isWord(s.codeUnitAt(end)));
}

bool _isLeadExtPre(int c) => c <= 0x20 || c == 0x28 || c == 0x5B || c == 0x60;

int _identDashEnd(String s, int i) {
  while (i < s.length &&
      (_isWord(s.codeUnitAt(i)) || s.codeUnitAt(i) == 0x2D)) {
    i++;
  }
  return i;
}

bool _isChainExtDot(String s, int d) {
  if (d == 0 || !_isIdentDash(s.codeUnitAt(d - 1))) return false;
  final (cur, last) = _walkDotChain(s, d);
  return last.isNotEmpty &&
      (cur == s.length || !_isWord(s.codeUnitAt(cur))) &&
      _dotExts.contains(last.toLowerCase());
}

bool _isIdentDash(int c) => _isWord(c) || c == 0x2D;

(int, String) _walkDotChain(String s, int d) {
  var cur = d, last = '';
  while (cur < s.length && s.codeUnitAt(cur) == 0x2E) {
    final end = _identDashEnd(s, cur + 1);
    if (end == cur + 1) break;
    last = s.substring(cur + 1, end);
    cur = end;
  }
  return (cur, last);
}

bool _isInlineListDot(String s, int d) {
  if (d == 0 || (s.codeUnitAt(d - 1) ^ 0x30) > 9) return false;
  final numStart = d >= 2 && (s.codeUnitAt(d - 2) ^ 0x30) <= 9 ? d - 2 : d - 1;
  if (numStart > 0 && !_isListPre(s.codeUnitAt(numStart - 1))) return false;
  final nx = _skipWs(s, d + 1);
  return nx > d + 1 && nx < s.length && _isLower(s.codeUnitAt(nx));
}

bool _isListPre(int c) => c <= 0x20 || c == 0x3A || c == 0x3B || c == 0x28;

int _skipWs(String s, int i) {
  while (i < s.length && s.codeUnitAt(i) <= 0x20) {
    i++;
  }
  return i;
}

bool _isAbbrevOrInitialDot(String s, int d) {
  final ws = _alphaDotWordStart(s, d);
  if (ws >= d || (ws > 0 && _isWord(s.codeUnitAt(ws - 1)))) return false;
  final wb = s.substring(ws, d);
  if (_isLetterDotRun(s, d, wb) || _tier1Abbrevs.contains(wb.toLowerCase())) {
    return true;
  }
  final nx = _nextAlphaWordAfterWs(s, d + 1);
  if (_tier2Abbrevs.contains(wb)) return !_etcStarters.contains(nx);
  return wb.length == 1 &&
      _isUpper(wb.codeUnitAt(0)) &&
      nx.isNotEmpty &&
      _isUpper(nx.codeUnitAt(0)) &&
      !_initialStarters.contains(nx);
}

int _alphaDotWordStart(String s, int d) {
  var i = d;
  while (i > 0 &&
      (_isAlpha(s.codeUnitAt(i - 1)) || s.codeUnitAt(i - 1) == 0x2E)) {
    i--;
  }
  return i < d && s.codeUnitAt(i) == 0x2E ? i + 1 : i;
}

bool _isLetterDotRun(String s, int d, String wb) =>
    (wb.length >= 3 &&
        wb.codeUnitAt(wb.length - 2) == 0x2E &&
        _isAlpha(wb.codeUnitAt(wb.length - 1)) &&
        _isAlpha(wb.codeUnitAt(wb.length - 3))) ||
    (wb.length == 1 &&
        _isAlpha(wb.codeUnitAt(0)) &&
        d + 2 < s.length &&
        _isAlpha(s.codeUnitAt(d + 1)) &&
        s.codeUnitAt(d + 2) == 0x2E &&
        (d + 3 == s.length || !_isWord(s.codeUnitAt(d + 3))));

String _nextAlphaWordAfterWs(String s, int from) {
  final i = _skipWs(s, from);
  if (i == from || i >= s.length || !_isAlpha(s.codeUnitAt(i))) return '';
  var e = i + 1;
  while (e < s.length && _isAlpha(s.codeUnitAt(e))) {
    e++;
  }
  return s.substring(i, e);
}

bool _isUpper(int c) => c >= 0x41 && c <= 0x5A;
bool _isLower(int c) => c >= 0x61 && c <= 0x7A;
bool _isAlpha(int c) => _isUpper(c) || _isLower(c);

void _emitSent(
  List<(int, String, int, int, bool)> o,
  String s,
  int b,
  (int, int) r,
) {
  final sub = s.substring(r.$1, r.$2);
  final lead = sub.length - sub.trimLeft().length;
  final txt = sub.trim(), wc = _countWords(txt);
  if (wc == 0) return;
  final pills = txt.contains(_codeSentinelChar)
      ? _codeSentinelChar.allMatches(txt).length
      : 0;
  o.add((b + r.$1 + lead, txt, wc, pills, txt.contains(_linkSentinelChar)));
}

void _maskMidParenDots(Uint16List u) {
  var depth = 0, mid = false;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    if (c == 0x28 && depth++ == 0) {
      mid = _hasNonEndPred(u, i);
    } else if (c == 0x29 && depth > 0) {
      depth--;
    } else if (depth > 0 && mid && _isEndP(c)) {
      u[i] = 0;
    }
  }
}

bool _isEndP(int c) => c == 0x2E || c == 0x21 || c == 0x3F;

bool _hasNonEndPred(Uint16List u, int idx) {
  for (var j = idx - 1; j >= 0; j--) {
    if (!_isWrapOrWs(u[j])) return !_isEndP(u[j]);
  }
  return false;
}

bool _isWrapOrWs(int c) =>
    c <= 0x20 ||
    const {0x22, 0x27, 0x29, 0x2A, 0x5D, 0x201D, 0x2019}.contains(c);
