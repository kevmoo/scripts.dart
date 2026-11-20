part of '../prose_check.dart';

const _codeSentinel = 0xE000, _linkSentinel = 0xE001, _escapeJoiner = 0xE002;
const _codeSentinelChar = '\uE000', _linkSentinelChar = '\uE001';

final _yamlFrontmatterRegex = RegExp(
  r'\A---[ \t]*\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)',
);
final _fenceLineRegex = RegExp(r'^\s*(?:>\s*)*(`{3,}|~{3,})(.*)$');
final _spotBlockRegex = RegExp(
  r'<!--\s*BEGIN SPOT:[^>]*-->[\s\S]*?<!--\s*END SPOT:[^>]*-->',
  caseSensitive: false,
);
final _sectionTagRegex = RegExp(r'</?section\b[^>]*>', caseSensitive: false);
final _attrBlockRegex = RegExp(r'\{[.#][A-Za-z0-9_-]+\}');
final _inlineDataUriRegex = RegExp(
  r'<data:image/[^>\s]+>',
  caseSensitive: false,
);
final _refDefPrefixRegex = RegExp(r'^[ ]{0,3}\[[^\]]+\]:\s*\S+');
final _autolinkRegex = RegExp(r'<https?://[^>\s]+>');
final _mdInlineLinkRegex = RegExp(
  r'\[([^\[\]]{0,500})\]\(((?:[^()\s]|\([^()\s]*\))+)'
  r'(?:\s+(?:"[^"]*"|\x27[^\x27]*\x27))?\)',
);
final _mdRefLinkRegex = RegExp(r'\[(?!\^)([^\[\]\n]+)\]\[([^\[\]\n]*)\]');
final _listItemIndentRegex = RegExp(r'^(\s*)(?:[-*+]|\d+[.)])\s+');

String _clipEx(String raw, [int maxLen = 48]) {
  final one = _collapsePrefix(raw, maxLen + 1);
  return one.length <= maxLen ? one : '${one.substring(0, maxLen)}...';
}

String _collapsePrefix(String raw, int limit) {
  final sb = StringBuffer();
  var inWs = true;
  for (var i = 0; i < raw.length && sb.length < limit; i++) {
    final c = raw.codeUnitAt(i);
    if (c <= 0x20) {
      inWs = true;
    } else {
      if (inWs && sb.isNotEmpty) sb.writeCharCode(0x20);
      sb.writeCharCode(c);
      inWs = false;
    }
  }
  return sb.toString();
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

  String contextEx(int off, [int pre = 20, int post = 28]) {
    final loc = locationAt(off);
    final (ls, le) = lineRange(loc.line);
    final s = math.max(ls, off - pre), e = math.min(le, off + post);
    final preDots = s > ls ? '...' : '', postDots = e < le ? '...' : '';
    return '$preDots${_clipEx(raw.substring(s, e), pre + post)}$postDots';
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
  final int activeEnd;
  final _LineIndex lineIndex;
  final List<(int offset, String content, bool plural)> codeSpans;
  final List<(int offset, String destination)> links;
  const new(
    this.raw,
    this.masked,
    this.activeEnd,
    this.lineIndex,
    this.codeSpans,
    this.links,
  );
}

void _fillSpaces(Uint16List u, int s, int e) {
  for (var i = s; i < e; i++) {
    if (u[i] != 0x0A && u[i] != 0x0D) u[i] = 0x20;
  }
}

void _maskRegexMatches(Uint16List u, RegExp re, [int? limit]) {
  final s = String.fromCharCodes(u, 0, limit ?? u.length);
  for (final m in re.allMatches(s)) {
    _fillSpaces(u, m.start, m.end);
  }
}

int _activeEnd(Uint16List u) {
  var end = u.length;
  while (end > 0 && u[end - 1] <= 0x20) {
    end--;
  }
  return end;
}

/// Returns the 1:1 newline-preserving masked Markdown buffer for tests.
@visibleForTesting
String debugMaskMarkdown(String raw) =>
    _maskDocument(raw, format: ProseFormat.markdown).masked;

_MaskedDoc _maskDocument(String raw, {required ProseFormat format}) {
  final idx = _LineIndex(raw);
  if (format == ProseFormat.text) {
    return _MaskedDoc(raw, raw, raw.length, idx, const [], const []);
  }
  final u = Uint16List.fromList(raw.codeUnits);
  if (raw.startsWith('---')) {
    if (_yamlFrontmatterRegex.firstMatch(raw) case final fm?) {
      _fillSpaces(u, 0, fm.end);
    }
  }
  if (raw.contains('```') || raw.contains('~~~')) {
    _maskFencedCodeBlocks(u, idx);
  }
  _maskLineDefsAndIndentedCode(u, idx);
  final lim = _activeEnd(u);
  _maskHtmlAndSpotBlocks(u, lim);
  final codes = _maskInlineCodeSpans(u, lim);
  final links = _maskLinksInsideOut(u, lim);
  _maskExportedEscapes(u, lim);
  return _MaskedDoc(raw, String.fromCharCodes(u), lim, idx, codes, links);
}

void _maskHtmlAndSpotBlocks(Uint16List u, int lim) {
  final lc = String.fromCharCodes(u, 0, lim).toLowerCase();
  if (lc.contains('<data:image/')) {
    _maskRegexMatches(u, _inlineDataUriRegex, lim);
  }
  if (lc.contains('begin spot:')) _maskRegexMatches(u, _spotBlockRegex, lim);
  _maskRawHtmlTags(u, lc);
  if (lc.contains('<!--')) _maskHtmlComments(u, lc);
  if (lc.contains('<section')) _maskRegexMatches(u, _sectionTagRegex, lim);
  if (lc.contains('{.') || lc.contains('{#')) {
    _maskRegexMatches(u, _attrBlockRegex, lim);
  }
}

void _maskRawHtmlTags(Uint16List u, String lc) {
  for (final tag in const ['details', 'pre', 'script', 'style']) {
    if (lc.contains('<$tag')) _maskTagBlocks(u, lc, tag);
  }
}

void _maskTagBlocks(Uint16List u, String lc, String tag) {
  final open = '<$tag', close = '</$tag';
  for (var s = lc.indexOf(open); s >= 0;) {
    final boundary = s + open.length;
    if (boundary < lc.length && _isAlpha(lc.codeUnitAt(boundary))) {
      s = lc.indexOf(open, boundary);
      continue;
    }
    final c = lc.indexOf(close, boundary);
    if (c < 0) return;
    final gt = lc.indexOf('>', c + close.length);
    final end = gt < 0 ? lc.length : gt + 1;
    _fillSpaces(u, s, end);
    s = lc.indexOf(open, end);
  }
}

void _maskHtmlComments(Uint16List u, String lc) {
  for (var s = lc.indexOf('<!--'); s >= 0;) {
    final c = lc.indexOf('-->', s + 4);
    final end = c < 0 ? lc.length : c + 3;
    _fillSpaces(u, s, end);
    s = lc.indexOf('<!--', end);
  }
}

void _maskExportedEscapes(Uint16List u, int lim) {
  for (var i = 0; i + 1 < lim; i++) {
    if (u[i] != 0x5C) continue;
    final nx = u[i + 1];
    if (nx == 0x5F || nx == 0x23) {
      u[i] = _escapeJoiner;
    } else if (_isEscapableSpacePunct(nx)) {
      u[i] = 0x20;
    }
  }
}

bool _isEscapableSpacePunct(int c) =>
    c == 0x7E || c == 0x2B || c == 0x2E || c == 0x21 || c == 0x2D;

void _maskFencedCodeBlocks(Uint16List u, _LineIndex idx) {
  var st = (0, 0);
  for (var ln = 1; ln <= idx.lineCount; ln++) {
    final (s, e) = idx.lineRange(ln);
    final head = String.fromCharCodes(
      u,
      s,
      math.min(e, s + 160),
    ).replaceAll('\r', '');
    final (next, mask) = _nextFence(st, head);
    st = next;
    if (mask) _fillSpaces(u, s, e);
  }
}

((int, int), bool) _nextFence((int, int) active, String line) {
  if (!line.contains('```') && !line.contains('~~~')) {
    return (active, active.$1 != 0);
  }
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
  var listInd = 0, prevBlank = true, inCode = false;
  for (var ln = 1; ln <= idx.lineCount; ln++) {
    final (s, e) = idx.lineRange(ln);
    final head = String.fromCharCodes(
      u,
      s,
      math.min(e, s + 200),
    ).replaceAll('\r', '');
    final trim = head.trim();
    if (trim.isEmpty ||
        trim == '&nbsp;' ||
        (trim.startsWith('[') && _refDefPrefixRegex.hasMatch(head))) {
      _fillSpaces(u, s, e);
      prevBlank = true;
    } else if (_isIndentedCode(head, trim, listInd, prevBlank || inCode)) {
      _fillSpaces(u, s, e);
      inCode = true;
    } else {
      inCode = prevBlank = false;
      listInd = _nextListIndent(head, trim, listInd);
    }
  }
}

bool _isIndentedCode(String l, String t, int ind, bool ok) =>
    ok && (l.length - l.trimLeft().length) >= ind + 4 && !_isBlockStart(l, t);

int _nextListIndent(String l, String t, int cur) =>
    (_mayStartList(t) ? _listItemIndentRegex.firstMatch(l)?.end : null) ??
    ((t.startsWith('#') || t.startsWith('|')) ? 0 : cur);

bool _isBlockStart(String l, String t) =>
    (_mayStartList(t) && _listItemIndentRegex.hasMatch(l)) ||
    t.startsWith('|') ||
    t.startsWith('#') ||
    t.startsWith('>');

bool _mayStartList(String t) {
  if (t.isEmpty) return false;
  final c = t.codeUnitAt(0);
  return c == 0x2D || c == 0x2A || c == 0x2B || (c ^ 0x30) <= 9;
}

int _tickRunEnd(String t, int i) {
  while (i < t.length && t.codeUnitAt(i) == 0x60) {
    i++;
  }
  return i;
}

List<(int, String, bool)> _maskInlineCodeSpans(Uint16List u, int lim) {
  final cur = String.fromCharCodes(u, 0, lim);
  var i = cur.indexOf('`');
  if (i < 0) return const [];
  final out = <(int, String, bool)>[];
  while (i >= 0 && i < cur.length) {
    final openEnd = _tickRunEnd(cur, i), k = openEnd - i;
    final closeS = _findClosingBackticks(cur, openEnd, k);
    if (closeS < 0) {
      i = cur.indexOf('`', openEnd);
      continue;
    }
    final closeE = closeS + k, plural = _hasPluralS(cur, closeE);
    out.add((i, cur.substring(openEnd, closeS), plural));
    u[i] = _codeSentinel;
    final end = plural ? closeE + 1 : closeE;
    _fillSpaces(u, i + 1, end);
    i = cur.indexOf('`', end);
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

List<(int, String)> _maskLinksInsideOut(Uint16List u, int lim) {
  final links = <(int, String)>[];
  final cur0 = String.fromCharCodes(u, 0, lim);
  if (cur0.contains('<http')) {
    for (final m in _autolinkRegex.allMatches(cur0)) {
      links.add((m.start, m[0]!.substring(1, m[0]!.length - 1)));
      u[m.start] = _linkSentinel;
      _fillSpaces(u, m.start + 1, m.end);
    }
  }
  final mayNest = cur0.contains('[![');
  if (_peelLinkLayer(u, lim, links) && mayNest) {
    while (_peelLinkLayer(u, lim, links)) {}
  }
  final curRef = String.fromCharCodes(u, 0, lim);
  if (curRef.contains('][')) _maskRefLinkTokens(u, curRef);
  return links;
}

void _scrubParens(Uint16List u, int s, int e) {
  for (var i = s; i < e; i++) {
    final c = u[i];
    if (c == 0x28 || c == 0x29) u[i] = 0x20;
  }
}

void _maskRefLinkTokens(Uint16List u, String cur) {
  for (final m in _mdRefLinkRegex.allMatches(cur)) {
    final bang = m.start > 0 && u[m.start - 1] == 0x21;
    if (bang) u[m.start - 1] = 0x20;
    u[m.start] = bang ? 0x20 : _linkSentinel;
    final lblEnd = m.start + 1 + m[1]!.length;
    if (!bang) _scrubParens(u, m.start + 1, lblEnd);
    _fillSpaces(u, lblEnd, m.end);
  }
}

bool _peelLinkLayer(Uint16List u, int lim, List<(int, String)> links) {
  final cur = String.fromCharCodes(u, 0, lim);
  if (!cur.contains('](')) return false;
  final ms = _mdInlineLinkRegex.allMatches(cur).toList();
  for (final m in ms) {
    final bang = m.start > 0 && u[m.start - 1] == 0x21;
    links.add((bang ? m.start - 1 : m.start, m[2]!.trim()));
    _scrubMatchedLink(u, bang, m);
  }
  return ms.isNotEmpty;
}

void _scrubMatchedLink(Uint16List u, bool bang, RegExpMatch m) {
  final lbl = m[1]!, t = lbl.trim();
  if (bang) u[m.start - 1] = 0x20;
  u[m.start] = bang ? 0x20 : _linkSentinel;
  final hide = t.startsWith('http://') || t.startsWith('https://');
  final lblEnd = m.start + 1 + lbl.length;
  if (!hide && !bang) _scrubParens(u, m.start + 1, lblEnd);
  _fillSpaces(u, hide ? m.start + 1 : lblEnd, m.end);
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
final _multiDotSemverRegex = RegExp(r'^\d+(?:\.\d+){2,}(?:-[A-Za-z0-9.-]+)?$');
final _twoPartVerRegex = RegExp(r'^\d+\.\d+$');
final _verPrevWordRegex = RegExp(
  r'\b(?:versions?|releases?|sdk|dart|flutter|semver|api|http|tls|oauth)\s+$',
  caseSensitive: false,
);
final _verNextWordRegex = RegExp(
  r'^\s+(?:versions?|releases?)\b',
  caseSensitive: false,
);

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
    final dead =
        loc.isNotEmpty &&
        FileSystemEntity.typeSync(loc) == FileSystemEntityType.notFound;
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

bool _hasAsciiDigit(String s) {
  for (var i = 0; i < s.length; i++) {
    if ((s.codeUnitAt(i) ^ 0x30) <= 9) return true;
  }
  return false;
}

bool _isVersionSpan(_LineIndex idx, int off, String t) {
  if (_multiDotSemverRegex.hasMatch(t)) return true;
  if (!_twoPartVerRegex.hasMatch(t)) return false;
  final loc = idx.locationAt(off);
  final (ls, le) = idx.lineRange(loc.line);
  final pre = idx.raw.substring(math.max(ls, off - 16), off);
  final end = (off + t.length + 2).clamp(ls, le);
  final post = idx.raw.substring(end, math.min(le, end + 16));
  return _verPrevWordRegex.hasMatch(pre) || _verNextWordRegex.hasMatch(post);
}

List<ProseSmell> _checkInlineCodeSmells(_MaskedDoc mask, ProseProfile prof) {
  final idx = mask.lineIndex, out = <ProseSmell>[];
  for (final (off, content, plural) in mask.codeSpans) {
    final t = content.trim();
    if (_hasAsciiDigit(t) &&
        !(prof == ProseProfile.readme && _readmeScalarIntRegex.hasMatch(t)) &&
        !_isVersionSpan(idx, off, t) &&
        _numericPillRegex.hasMatch(t)) {
      out.add(
        idx.sm(
          off,
          'numeric-backtick: Number or rate in backticks',
          '`${_clipEx(t)}`',
        ),
      );
    }
    if (plural) {
      out.add(
        idx.sm(
          off,
          'code-span-plural: Plural suffix on code',
          '`${_clipEx(t)}`s',
        ),
      );
    }
  }
  return out;
}
