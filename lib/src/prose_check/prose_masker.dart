part of '../prose_check.dart';

const _codeSentinel = 0xE000, _linkSentinel = 0xE001;
const _codeSentinelChar = '\uE000', _linkSentinelChar = '\uE001';

final _yamlFrontmatterRegex = RegExp(
  r'\A---[ \t]*\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)',
);
final _fenceLineRegex = RegExp(r'^\s*(?:>\s*)*(`{3,}|~{3,})(.*)$');
final _spotBlockRegex = RegExp(
  r'<!--\s*BEGIN SPOT:[^>]*-->[\s\S]*?<!--\s*END SPOT:[^>]*-->',
  caseSensitive: false,
);
final _detailsOrPreRegex = RegExp(
  r'<(?:details|pre|script|style)\b[^>]*>[\s\S]*?</(?:details|pre|script|style)>',
  caseSensitive: false,
);
final _commentOrAttrRegex = RegExp(
  r'<!--[\s\S]*?-->|</?section\b[^>]*>|\{[.#][A-Za-z0-9_-]+\}',
  caseSensitive: false,
);
final _refDefOrDataLineRegex = RegExp(
  r'^[ ]{0,3}\[[^\]]+\]:\s*\S+|<data:image/[^>\s]+>',
  caseSensitive: false,
);
final _autolinkRegex = RegExp(r'<https?://[^>\s]+>');
final _mdInlineLinkRegex = RegExp(
  r'!?\[([^\[\]]*)\]\(((?:[^()\s]+|\([^()\s]*\))+)'
  r'(?:\s+(?:"[^"]*"|\x27[^\x27]*\x27))?\)',
);
final _mdRefLinkRegex = RegExp(r'!?\[(?!\^)([^\[\]\n]+)\]\[([^\[\]\n]*)\]');
final _exportedEscapedPunctRegex = RegExp(r'(?<!\w)\\(?=[~#+.!-])');
final _listItemIndentRegex = RegExp(r'^(\s*)(?:[-*+]|\d+[.)])\s+');

String _clipEx(String raw, [int maxLen = 48]) {
  final one = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= maxLen ? one : '${one.substring(0, maxLen)}...';
}

final class _LineIndex {
  final String raw;
  final List<int> _starts;

  new(this.raw)
    : _starts = [
        0,
        for (var i = 0; i < raw.length; i++)
          if (raw.codeUnitAt(i) == 0x0A) i + 1,
      ];

  int get lineCount => _starts.length;

  (int, int) lineRange(int ln) =>
      (_starts[ln - 1], ln < _starts.length ? _starts[ln] - 1 : raw.length);

  ({int line, int column}) locationAt(int offset) {
    final c = offset.clamp(0, raw.length);
    var lo = 0, hi = _starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= c) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (line: lo + 1, column: c - _starts[lo] + 1);
  }

  String spanEx(int off, [int len = 48]) {
    final s = off.clamp(0, raw.length);
    return _clipEx(raw.substring(s, (s + len).clamp(s, raw.length)));
  }

  ProseSmell mark(int off, SmellSeverity sev, String idMsg, [String? ex]) {
    final c = idMsg.indexOf(':'), loc = locationAt(off);
    return ProseSmell(
      smellId: idMsg.substring(0, c),
      severity: sev,
      line: loc.line,
      column: loc.column,
      summary: idMsg.substring(c + 1).trimLeft(),
      excerpt: ex ?? spanEx(off),
    );
  }

  ProseSmell hi(int off, String idMsg, [String? ex]) =>
      mark(off, SmellSeverity.high, idMsg, ex);

  ProseSmell sm(int off, String idMsg, [String? ex]) =>
      mark(off, SmellSeverity.smell, idMsg, ex);

  ProseSmell by(int off, bool high, String idMsg, [String? ex]) =>
      mark(off, high ? SmellSeverity.high : SmellSeverity.smell, idMsg, ex);
}

final class _MaskedDoc {
  final String raw, masked;
  final _LineIndex lineIndex;
  final List<(int offset, String content, bool plural)> codeSpans;
  final List<(int offset, String destination)> links;
  const new(this.raw, this.masked, this.lineIndex, this.codeSpans, this.links);
}

void _fillSpaces(Uint16List u, int s, int e) {
  for (var i = s; i < e; i++) {
    if (u[i] != 0x0A && u[i] != 0x0D) u[i] = 0x20;
  }
}

void _maskRegexMatches(Uint16List u, RegExp re) {
  for (final m in re.allMatches(String.fromCharCodes(u))) {
    _fillSpaces(u, m.start, m.end);
  }
}

/// Returns the 1:1 newline-preserving masked Markdown buffer for tests.
@visibleForTesting
String debugMaskMarkdown(String raw) =>
    _maskDocument(raw, format: ProseFormat.markdown).masked;

_MaskedDoc _maskDocument(String raw, {required ProseFormat format}) {
  final idx = _LineIndex(raw);
  if (format == ProseFormat.text) {
    return _MaskedDoc(raw, raw, idx, const [], const []);
  }
  final u = Uint16List.fromList(raw.codeUnits);
  if (_yamlFrontmatterRegex.firstMatch(raw) case final fm?) {
    _fillSpaces(u, 0, fm.end);
  }
  _maskFencedCodeBlocks(u, idx);
  _maskRegexMatches(u, _spotBlockRegex);
  _maskRegexMatches(u, _detailsOrPreRegex);
  _maskRegexMatches(u, _commentOrAttrRegex);
  _maskLineDefsAndIndentedCode(u, idx);
  final codes = _maskInlineCodeSpans(u), links = _maskLinksInsideOut(u);
  _maskRegexMatches(u, _exportedEscapedPunctRegex);
  return _MaskedDoc(raw, String.fromCharCodes(u), idx, codes, links);
}

void _maskFencedCodeBlocks(Uint16List u, _LineIndex idx) {
  final cur = String.fromCharCodes(u);
  var st = (0, 0);
  for (var ln = 1; ln <= idx.lineCount; ln++) {
    final (s, e) = idx.lineRange(ln);
    final (next, mask) = _nextFence(
      st,
      cur.substring(s, e).replaceAll('\r', ''),
    );
    st = next;
    if (mask) _fillSpaces(u, s, e);
  }
}

((int, int), bool) _nextFence((int, int) active, String line) {
  final m = _fenceLineRegex.firstMatch(line);
  if (m == null) return (active, active.$1 != 0);
  final d = m[1]!;
  if (active.$1 == 0) return ((d.codeUnitAt(0), d.length), true);
  final end =
      d.codeUnitAt(0) == active.$1 &&
      d.length >= active.$2 &&
      m[2]!.trim().isEmpty;
  return (end ? (0, 0) : active, true);
}

void _maskLineDefsAndIndentedCode(Uint16List u, _LineIndex idx) {
  final cur = String.fromCharCodes(u);
  var listInd = 0, prevBlank = true, inCode = false;
  for (var ln = 1; ln <= idx.lineCount; ln++) {
    final (s, e) = idx.lineRange(ln);
    final line = cur.substring(s, e).replaceAll('\r', ''), trim = line.trim();
    if (trim.isEmpty ||
        trim == '&nbsp;' ||
        _refDefOrDataLineRegex.hasMatch(line)) {
      _fillSpaces(u, s, e);
      prevBlank = true;
    } else if (_isIndentedCode(line, trim, listInd, prevBlank || inCode)) {
      _fillSpaces(u, s, e);
      inCode = true;
    } else {
      inCode = prevBlank = false;
      listInd = _nextListIndent(line, trim, listInd);
    }
  }
}

bool _isIndentedCode(String l, String t, int ind, bool ok) =>
    ok && (l.length - l.trimLeft().length) >= ind + 4 && !_isBlockStart(l, t);

int _nextListIndent(String l, String t, int cur) =>
    _listItemIndentRegex.firstMatch(l)?.end ??
    ((t.startsWith('#') || t.startsWith('|')) ? 0 : cur);

bool _isBlockStart(String l, String t) =>
    _listItemIndentRegex.hasMatch(l) ||
    t.startsWith('|') ||
    t.startsWith('#') ||
    t.startsWith('>');

int _tickRunEnd(String t, int i) {
  while (i < t.length && t.codeUnitAt(i) == 0x60) {
    i++;
  }
  return i;
}

List<(int, String, bool)> _maskInlineCodeSpans(Uint16List u) {
  final cur = String.fromCharCodes(u), out = <(int, String, bool)>[];
  for (var i = 0; i < cur.length;) {
    if (cur.codeUnitAt(i) != 0x60) {
      i++;
      continue;
    }
    final openEnd = _tickRunEnd(cur, i), k = openEnd - i;
    final closeS = _findClosingBackticks(cur, openEnd, k);
    if (closeS < 0) {
      i = openEnd;
      continue;
    }
    final closeE = closeS + k, plural = _hasPluralS(cur, closeE);
    out.add((i, cur.substring(openEnd, closeS), plural));
    u[i] = _codeSentinel;
    final end = plural ? closeE + 1 : closeE;
    _fillSpaces(u, i + 1, end);
    i = end;
  }
  return out;
}

int _findClosingBackticks(String t, int from, int k) {
  for (var j = from; j < t.length;) {
    if (t.codeUnitAt(j) == 0x0A &&
        j + 1 < t.length &&
        t.codeUnitAt(j + 1) == 0x0A) {
      return -1;
    }
    if (t.codeUnitAt(j) != 0x60) {
      j++;
      continue;
    }
    final end = _tickRunEnd(t, j);
    if (end - j == k) return j;
    j = end;
  }
  return -1;
}

bool _hasPluralS(String t, int i) =>
    i < t.length &&
    t.codeUnitAt(i) == 0x73 &&
    (i + 1 >= t.length || !_isWord(t.codeUnitAt(i + 1)));

bool _isWord(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A) ||
    c == 0x5F;

List<(int, String)> _maskLinksInsideOut(Uint16List u) {
  final links = <(int, String)>[];
  for (final m in _autolinkRegex.allMatches(String.fromCharCodes(u))) {
    links.add((m.start, m[0]!.substring(1, m[0]!.length - 1)));
    u[m.start] = _linkSentinel;
    _fillSpaces(u, m.start + 1, m.end);
  }
  while (_peelLinkLayer(u, links)) {}
  for (final m in _mdRefLinkRegex.allMatches(String.fromCharCodes(u))) {
    final bang = m[0]!.startsWith('!'), br = m.start + (bang ? 1 : 0);
    if (bang) u[m.start] = 0x20;
    u[br] = bang ? 0x20 : _linkSentinel;
    _fillSpaces(u, br + 1 + m[1]!.length, m.end);
  }
  return links;
}

bool _peelLinkLayer(Uint16List u, List<(int, String)> links) {
  final cur = String.fromCharCodes(u);
  final ms = _mdInlineLinkRegex.allMatches(cur).toList();
  for (final m in ms) {
    links.add((m.start, m[2]!.trim()));
    _scrubMatchedLink(u, cur.codeUnitAt(m.start) == 0x21, m);
  }
  return ms.isNotEmpty;
}

void _scrubMatchedLink(Uint16List u, bool bang, RegExpMatch m) {
  final br = bang ? m.start + 1 : m.start;
  final lbl = m[1]!, t = lbl.trim();
  if (bang) u[m.start] = 0x20;
  u[br] = bang ? 0x20 : _linkSentinel;
  final hide = t.startsWith('http://') || t.startsWith('https://');
  _fillSpaces(u, hide ? br + 1 : br + 1 + lbl.length, m.end);
}

final _numericPillRegex = RegExp(
  r'^[~<>=\u2264\u2265+-]*\s*(?:\d{4}-\d{2}-\d{2}|(?:Jan|Feb|Mar|Apr|May|Jun|'
  r'Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*(?:\s+\d{1,2}(?:,?\s+\d{4})?|\s+\d{4})|\d+'
  r'(?:[.,]\d+)*\s*(?:OK|Not\s+Found)?(?:\s*(?:to|-|\u2013|/)\s*[~<>=\u2264'
  r'\u2265+-]?\s*\d+(?:[.,]\d+)*)*(?:\s*(?:%|ms|s|m|h|d|w|k|M|B|KB|MB|GB|TB|x|'
  r'YoY|reqs?/hr|hits?/day|fetches/day|/day|/hr|/100w|words?|days?|hours?|'
  r'mins?|minutes?)\+?)?(?:\s*\([~<>=\u2264\u2265+-]*\d+(?:[.,]\d+)*%?\))?)$',
  caseSensitive: false,
);
final _readmeScalarIntRegex = RegExp(r'^\d{1,4}$');

List<ProseSmell> _checkLinkSmells(_MaskedDoc mask, Directory? baseDir) => [
  for (final (off, dest) in mask.links)
    ..._singleLinkSmells(mask.lineIndex, baseDir, off, dest),
];

List<ProseSmell> _singleLinkSmells(
  _LineIndex idx,
  Directory? base,
  int off,
  String d,
) {
  final ex = _clipEx(d);
  if (d.startsWith('file://')) {
    final loc = d.substring('file://'.length).split('#').first;
    final dead = loc.isNotEmpty && !File(loc).existsSync();
    return [
      idx.sm(off, 'unportable-file-uri: Local file:// URI is not portable', ex),
      if (dead) idx.hi(off, 'broken-local-link: Target file missing', ex),
    ];
  }
  if (base == null || !_isRelTarget(d)) return const [];
  final rel = d.split('#').first.split('?').first;
  final res = p.normalize(p.join(base.path, rel));
  if (rel.isEmpty || File(res).existsSync() || Directory(res).existsSync()) {
    return const [];
  }
  return [idx.hi(off, 'broken-local-link: Relative link target missing', ex)];
}

bool _isRelTarget(String d) =>
    !d.startsWith('#') &&
    !d.startsWith('/') &&
    !d.contains('://') &&
    !d.startsWith('mailto:') &&
    !d.startsWith('data:');

List<ProseSmell> _checkInlineCodeSmells(_MaskedDoc mask, ProseProfile prof) {
  final idx = mask.lineIndex, out = <ProseSmell>[];
  for (final (off, content, plural) in mask.codeSpans) {
    final t = content.trim(), ex = '`${_clipEx(t)}`';
    final okInt =
        prof == ProseProfile.readme && _readmeScalarIntRegex.hasMatch(t);
    if (_numericPillRegex.hasMatch(t) && !okInt) {
      out.add(idx.sm(off, 'numeric-backtick: Number or rate in backticks', ex));
    }
    if (plural) {
      out.add(idx.sm(off, 'code-span-plural: Plural suffix on code', '${ex}s'));
    }
  }
  return out;
}
