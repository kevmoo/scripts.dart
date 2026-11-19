part of '../prose_check.dart';

final _taskMarkerRegex = RegExp(r'^\[[ xX]\]\s+');
final _leadingLabelRegex = RegExp(
  r'^(?:\*\*([^*]+)\*\*\s*:?|\*([^*]+)\*\s*:)\s*',
);
final _metaHeaderLineRegex = RegExp(r'^(?:\*?[A-Za-z ]+:\*?\s+\S+\s*){2,}$');
final _alertHeaderRegex = RegExp(
  r'^>\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$',
);
final _hrLineRegex = RegExp(r'^[-*_]{3,}\s*$');
final _headingPrefixRegex = RegExp(r'^(#{1,6})\s+');
final _unescapedPipeRegex = RegExp(r'(?<!\\)\|');
final _tableSepCellRegex = RegExp(r'^:?-{2,}:?$');
final _enumParenRegex = RegExp(r'\(\s*(?:\d{1,2}|[a-z]|[ivx]{1,4})\s*\)');
final _footnoteRefRegex = RegExp(r'\[\^[^\]]+\]');

final _sentenceDotMaskRegexes = <RegExp>[
  RegExp(
    r'\.{3,}|\u2026|\b(?:[A-Za-z]\.){2,}|'
    r'(?<=\b[A-Z])\.(?=\s+(?!(?:However|Therefore|Thus|The|This|That|In|On|At|'
    r'For|When|While|If|We|It|They|Our)\b)[A-Z])',
  ),
  RegExp(
    r'\b(?:vs|v|e\.g|i\.e|incl|approx|cf|al|viz|ca|Mr|Ms|Mrs|Dr|Prof|St|Fig|'
    r'Figs|No|p|pp)\.',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(?:etc|Inc|Corp|Ltd|Co|Jr|Sr)\.(?!\s+(?:However|Therefore|Thus|'
    r'Moreover|Furthermore|Instead|Meanwhile|Next|First|Second|Third|Finally|'
    r'The|This|That|These|Those|In|On|At|For|When|While|Where|Because|Although|'
    r'If|We|It|They|Our)\b)',
  ),
  RegExp(
    r'(?<=\d)\.(?=\d)|(?<=[:;(\s])\d{1,2}\.(?=\s+[a-z])|'
    r'(?:^|(?<=[\s(\[`]))\.[A-Za-z0-9_-]{1,12}\b',
  ),
  RegExp(
    r'\b(?:[A-Za-z0-9_-]+\.)+(?:dev|com|org|io|net|gov|edu|uk|md|txt|py|go|js|'
    r'ts|sql|pbtxt|tf|html|yaml|yml|json|dart|cc|h|sh|toml|lock)\b',
    caseSensitive: false,
  ),
];
final _sentenceBoundaryRegex = RegExp(
  r'[.!?](?:["\x27\u201d\u2019)\]*]+)?(?:\[\^[^\]]+\])*(?=\s+|$)',
);
final _wordRegex = RegExp(
  r"\uE000|\d+(?:[.,]\d+)*(?:[-'/][A-Za-z0-9_]+)*"
  r"|[A-Za-z0-9_]+(?:[-'/][A-Za-z0-9_]+)*",
);
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

int _countWords(String text) =>
    _wordRegex.allMatches(text.replaceAll(_footnoteRefRegex, ' ')).length;

_ExtractedDoc _extractDocument(_MaskedDoc m, ProseProfile p, ProseFormat f) {
  final st = _ExtractorState(m, p, f);
  for (var ln = 1; ln <= m.lineIndex.lineCount; ln++) {
    st.consumeLine(ln);
  }
  st
    ..flushBlock()
    ..flushTable();
  return _ExtractedDoc(m, p, f, st.blocks, st.tables);
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
    : cleanUnits = Uint16List.fromList(mask.masked.codeUnits);

  void consumeLine(int ln) {
    final (s, e) = mask.lineIndex.lineRange(ln);
    final rawL = mask.raw.substring(s, e), maskL = mask.masked.substring(s, e);
    if (maskL.trim().isEmpty) {
      flushBlock();
      return flushTable();
    }
    if (format == ProseFormat.markdown && _consumeMd(ln, (s, e), rawL, maskL)) {
      return;
    }
    flushTable();
    final noCr = maskL.replaceAll('\r', '');
    if (_listItemIndentRegex.firstMatch(noCr) case final b?) {
      flushBlock();
      blockStart = s;
      blockEnd = e;
      isBullet = true;
      final tm = _taskMarkerRegex.firstMatch(noCr.substring(b.end));
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
      flushBlock();
      _consumeTableRow(ln, r.$1, rawL, maskL);
      return true;
    }
    if (_headingPrefixRegex.firstMatch(strip) case final hm?) {
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

  void _consumeTableRow(int ln, int s, String rawL, String maskL) {
    final p1 = maskL.indexOf('|'), p2 = maskL.lastIndexOf('|');
    if (p2 <= p1) return;
    final inS = p1 + 1, inMask = maskL.substring(inS, p2);
    final inRaw = rawL.substring(inS, math.min(p2, rawL.length));
    final spans = _splitPipeOffsets(inMask);
    if (tableCols == null) _initTableHeader(ln, s + p1, inRaw, spans);
    if (_isSepRow(inMask, spans) || (tableCols ?? 0) < 2) return;
    if (tableRowIndex++ > 0) _recordRowCells(s + inS, inMask, inRaw, spans);
  }

  void _initTableHeader(int ln, int off, String inRaw, List<(int, int)> spans) {
    final end = spans.isEmpty ? 0 : math.min(spans.first.$2, inRaw.length);
    final first = spans.isEmpty ? '' : inRaw.substring(spans.first.$1, end);
    final key = first.replaceAll(RegExp(r'[*_`]'), '').trim().toLowerCase();
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
    _hrLineRegex.hasMatch(s) ||
    s == '[TOC]' ||
    _alertHeaderRegex.hasMatch(s) ||
    rawT.startsWith('![') ||
    (rawT.startsWith('[![') && _countWords(s) <= 6);

bool _isSepRow(String inner, List<(int, int)> spans) => spans.every((s) {
  final c = inner.substring(s.$1, s.$2).trim();
  return c.isEmpty || _tableSepCellRegex.hasMatch(c);
});

List<(int, int)> _splitPipeOffsets(String inner) {
  final out = <(int, int)>[];
  var last = 0;
  for (final m in _unescapedPipeRegex.allMatches(inner)) {
    out.add((last, m.start));
    last = m.end;
  }
  return out..add((last, inner.length));
}

_ProseBlock? _buildBlock(Uint16List u, (int, int) r, bool bul, ProseProfile p) {
  final sub = u.sublist(r.$1, r.$2);
  final raw = String.fromCharCodes(sub), trim = raw.trim();
  if (trim.isEmpty || _metaHeaderLineRegex.hasMatch(trim)) return null;
  final (lead, pOff, bRel) = bul ? _parseLead(raw, r.$1, p) : (false, null, 0);
  _maskTopLevelEnumParens(sub);
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
  _maskMidParenDots(u);
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
  for (final m in [
    for (final r in _sentenceDotMaskRegexes) ...r.allMatches(slice),
  ]) {
    for (var i = m.start; i < m.end; i++) {
      if (u[i] == 0x2E || u[i] == 0x2026) u[i] = 0;
    }
  }
  return u;
}

void _emitSent(
  List<(int, String, int, int, bool)> o,
  String s,
  int b,
  (int, int) r,
) {
  final sub = s.substring(r.$1, r.$2),
      lead = sub.length - sub.trimLeft().length;
  final txt = sub.trim(), wc = _countWords(txt);
  if (wc == 0) return;
  final pills = _codeSentinelChar.allMatches(txt).length;
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
