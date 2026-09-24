/// Alignment options for GitHub Flavored Markdown table columns.
enum MdAlign {
  left(':---'),
  center(':---:'),
  right('---:'),
  none('---');

  final String marker;
  new(this.marker);
}

/// Sanitizes a single-line string for safe inclusion inside a Markdown table
/// cell without splitting columns or breaking rows.
///
/// Strips carriage returns (`\r`), normalizes newlines (`\n`) to spaces,
/// replaces pipe characters (`|`) with [pipeReplacement] (default `'/'`), and
/// trims surrounding whitespace.
String sanitizeMarkdownCell(String input, {String pipeReplacement = '/'}) =>
    input
        .replaceAll('\r\n', ' ')
        .replaceAll('\r', '')
        .replaceAll('\n', ' ')
        .replaceAll('|', pipeReplacement)
        .trim();

/// Sanitizes and joins a multi-line sequence of cell lines using `<br>`.
///
/// Each element in [lines] has embedded `\r\n`/`\n` converted to `<br>` and
/// `|` replaced with [pipeReplacement]. If [nbsp] is `true`, spaces within each
/// line are replaced with `&nbsp;` to prevent intra-line wrapping.
String formatMarkdownCellLines(
  Iterable<String> lines, {
  bool nbsp = false,
  String pipeReplacement = '/',
}) => lines
    .map((line) {
      final sanitized = line
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '')
          .replaceAll('|', pipeReplacement)
          .split('\n')
          .map((part) => part.trim())
          .join('<br>');
      return nbsp ? sanitized.replaceAll(' ', '&nbsp;') : sanitized;
    })
    .join('<br>');

/// Formats a single Markdown table row (`| cell1 | cell2 |`), sanitizing each
/// cell via [sanitizeMarkdownCell].
String formatMarkdownRow(
  Iterable<String> cells, {
  String pipeReplacement = '/',
}) {
  final formatted = cells
      .map((c) => sanitizeMarkdownCell(c, pipeReplacement: pipeReplacement))
      .join(' | ');
  return '| $formatted |';
}

/// Writes a complete Markdown table to [buffer], wrapped in
/// `<!-- mdformat off(prevent table wrapping) -->` and `<!-- mdformat on -->`
/// guards by default.
void writeMarkdownTable(
  StringBuffer buffer, {
  required List<String> headers,
  required Iterable<List<String>> rows,
  List<MdAlign>? alignments,
  bool mdformatGuard = true,
  String pipeReplacement = '/',
}) {
  if (mdformatGuard) {
    buffer.writeln('<!-- mdformat off(prevent table wrapping) -->');
  }

  buffer.writeln(formatMarkdownRow(headers, pipeReplacement: pipeReplacement));

  final sepCells = List<String>.generate(
    headers.length,
    (i) => alignments != null && i < alignments.length
        ? alignments[i].marker
        : MdAlign.left.marker,
  );
  buffer.writeln('| ${sepCells.join(' | ')} |');

  for (final row in rows) {
    buffer.writeln(formatMarkdownRow(row, pipeReplacement: pipeReplacement));
  }

  if (mdformatGuard) {
    buffer.writeln('<!-- mdformat on -->');
  }
}

/// Formats and returns a complete Markdown table string (without a trailing
/// newline), wrapped in `mdformat` table-wrapping guards by default.
String formatMarkdownTable({
  required List<String> headers,
  required Iterable<List<String>> rows,
  List<MdAlign>? alignments,
  bool mdformatGuard = true,
  String pipeReplacement = '/',
}) {
  final buffer = StringBuffer();
  writeMarkdownTable(
    buffer,
    headers: headers,
    rows: rows,
    alignments: alignments,
    mdformatGuard: mdformatGuard,
    pipeReplacement: pipeReplacement,
  );
  return buffer.toString().trimRight();
}
