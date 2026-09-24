/// Sanitizes [input] for safe interpolation inside a Markdown table cell.
///
/// Strips carriage returns (`\r`), replaces pipe characters (`|`) with `'/'`,
/// trims surrounding whitespace, and replaces newlines (`\n`) with spaces
/// (or `'<br>'` when [newlinesToBr] is `true`).
String sanitizeMarkdownCell(String input, {bool newlinesToBr = false}) => input
    .trim()
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '')
    .replaceAll('|', '/')
    .replaceAll('\n', newlinesToBr ? '<br>' : ' ');
