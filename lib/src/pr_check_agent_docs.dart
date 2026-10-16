part of 'pr_check.dart';

/// Maximum line count allowed for a `SKILL.md` file before progressive
/// disclosure into `references/*.md` is required.
const maxSkillMdLines = 350;

/// Maximum line count allowed for always-on instruction files (`AGENTS.md`,
/// `CLAUDE.md`, `GEMINI.md`).
const maxAgentsMdLines = 200;

/// Maximum character length for a `SKILL.md` YAML `description` field.
const maxSkillDescriptionChars = 1024;

const _alwaysOnAgentDocNames = {'AGENTS.md', 'CLAUDE.md', 'GEMINI.md'};

const _proseFenceLangs = {'markdown', 'md', 'text', 'txt', 'plaintext', 'diff'};

final _unicodeDashRegex = RegExp(r'[\u2014\u2013]');
final _inlineCodeSpanRegex = RegExp(r'`([^`]+)`');
final _inlineCliFlagUnicodeDashRegex = RegExp(
  r'(?:^|\s)[\u2014\u2013][A-Za-z0-9]',
);
final _markdownLinkRegex = RegExp(r'\[[^\]]+\]\(([^)]+)\)');
final _skillNamePattern = RegExp(r'^[a-z0-9-]+$');

final class _FenceState {
  final String delimiter;
  final String lang;

  const new({required this.delimiter, required this.lang});
}

_FenceState? _updateFenceState(_FenceState? activeFence, String line) {
  final match = RegExp(r'^\s*(`{3,}|~{3,})(.*)$').firstMatch(line);
  if (match == null) return activeFence;
  final fence = match.group(1)!;
  final rest = match.group(2)!.trim();
  if (activeFence == null) {
    final lang = rest.split(RegExp(r'\s+')).first.toLowerCase();
    return _FenceState(delimiter: fence, lang: lang);
  }
  final isClosing = fence.startsWith(activeFence.delimiter) && rest.isEmpty;
  return isClosing ? null : activeFence;
}

PrCheckViolation? _checkFencedMarkdownLine(
  String relPath,
  int lineNumber,
  String line,
  _FenceState? activeFence,
  _FenceState? nextFence,
) {
  if (activeFence == null || nextFence == null) return null;
  if (_proseFenceLangs.contains(activeFence.lang) ||
      !_unicodeDashRegex.hasMatch(line)) {
    return null;
  }
  return PrCheckViolation(
    check: 'markdown-code-unicode-dash',
    message:
        '$relPath:$lineNumber contains a Unicode em/en-dash (— or –) inside '
        'a fenced code block.',
    remediation: 'Replace — or – with ASCII -- or - inside code blocks.',
  );
}

PrCheckViolation? _checkInlineCodeFlagDashes(
  String relPath,
  int lineNumber,
  String line,
) {
  for (final match in _inlineCodeSpanRegex.allMatches(line)) {
    final span = match.group(1)!;
    if (_inlineCliFlagUnicodeDashRegex.hasMatch(span)) {
      return PrCheckViolation(
        check: 'markdown-code-unicode-dash',
        message:
            '$relPath:$lineNumber contains a Unicode dash flag prefix inside '
            'inline code (`$span`).',
        remediation: 'Replace — or – with ASCII -- or - in CLI flags.',
      );
    }
  }
  return null;
}

bool _isAgentDocPath(String relPath) {
  final base = p.basename(relPath);
  if (base == 'SKILL.md' || _alwaysOnAgentDocNames.contains(base)) {
    return true;
  }
  final segments = p.split(relPath);
  return segments.contains('references') && relPath.endsWith('.md');
}

/// Validates agentic documentation files (`SKILL.md`, `AGENTS.md`, `CLAUDE.md`,
/// `GEMINI.md`, and `references/*.md`) for line budgets, frontmatter trigger
/// contracts, and relative link integrity.
List<PrCheckViolation> checkAgentDocFiles(
  Directory repoRoot,
  List<String> mdFiles,
) {
  final violations = <PrCheckViolation>[];
  for (final relPath in mdFiles) {
    if (!_isAgentDocPath(relPath)) continue;
    violations.addAll(checkSingleAgentDocFile(repoRoot, relPath));
  }
  return violations;
}

/// Validates a single agentic documentation file at [relPath] under [repoRoot].
List<PrCheckViolation> checkSingleAgentDocFile(
  Directory repoRoot,
  String relPath,
) {
  final file = File(p.join(repoRoot.path, relPath));
  if (!file.existsSync()) return const [];
  final lines = file.readAsLinesSync();
  final base = p.basename(relPath);
  final violations = <PrCheckViolation>[];

  if (base == 'SKILL.md') {
    final budgetViolation = _checkLineBudget(
      relPath,
      lines.length,
      maxSkillMdLines,
      'Offload detailed schemas, tables, or templates into '
      'references/<topic>.md.',
    );
    if (budgetViolation != null) violations.add(budgetViolation);
    violations
      ..addAll(checkSkillFrontmatter(relPath, lines))
      ..addAll(
        _checkUnlinkedSkillReferences(repoRoot, relPath, lines.join('\n')),
      );
  } else if (_alwaysOnAgentDocNames.contains(base)) {
    final budgetViolation = _checkLineBudget(
      relPath,
      lines.length,
      maxAgentsMdLines,
      'Move domain-specific standards to a standalone reference file and link '
      'it on demand.',
    );
    if (budgetViolation != null) violations.add(budgetViolation);
  }

  violations.addAll(_checkRelativeMarkdownLinks(repoRoot, relPath, lines));
  return violations;
}

PrCheckViolation? _checkLineBudget(
  String relPath,
  int lineCount,
  int maxLines,
  String remediation,
) {
  if (lineCount <= maxLines) return null;
  return PrCheckViolation(
    check: 'agent-doc-line-budget',
    message:
        '$relPath has $lineCount lines, exceeding the $maxLines-line ceiling.',
    remediation: remediation,
  );
}

/// Validates YAML frontmatter and trigger-only `description` rules for a
/// `SKILL.md` file's [lines].
List<PrCheckViolation> checkSkillFrontmatter(
  String relPath,
  List<String> lines,
) {
  final closingIdx = _findFrontmatterClosingIndex(lines);
  if (closingIdx == null) {
    return [
      PrCheckViolation(
        check: 'skill-frontmatter',
        message: '$relPath is missing a leading --- YAML frontmatter block.',
        remediation:
            'Add a YAML frontmatter block with `name` and `description: >-` '
            'at the top of $relPath.',
      ),
    ];
  }

  final rawFrontmatter = lines.sublist(1, closingIdx).join('\n');
  YamlMap? map;
  try {
    final parsed = loadYaml(rawFrontmatter);
    if (parsed is YamlMap) map = parsed;
  } on Object {
    map = null;
  }
  if (map == null) {
    return [
      PrCheckViolation(
        check: 'skill-frontmatter',
        message: '$relPath has invalid YAML frontmatter.',
        remediation: 'Fix YAML syntax inside the leading --- block.',
      ),
    ];
  }

  final violations = <PrCheckViolation>[];
  final nameViolation = _checkSkillNameField(relPath, map['name']);
  if (nameViolation != null) violations.add(nameViolation);
  violations.addAll(
    _checkSkillDescriptionField(relPath, rawFrontmatter, map['description']),
  );
  return violations;
}

int? _findFrontmatterClosingIndex(List<String> lines) {
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') return i > 1 ? i : null;
  }
  return null;
}

PrCheckViolation? _checkSkillNameField(String relPath, Object? rawName) {
  final name = rawName is String ? rawName.trim() : '';
  if (name.isEmpty || !_skillNamePattern.hasMatch(name)) {
    return PrCheckViolation(
      check: 'skill-frontmatter',
      message:
          '$relPath frontmatter must define a lowercase hyphenated `name` '
          '(^[a-z0-9-]+\$).',
      remediation: 'Set `name: <skill-slug>` in $relPath frontmatter.',
    );
  }
  final parentDir = p.basename(p.dirname(relPath));
  if (parentDir != '.' && parentDir != 'skills' && name != parentDir) {
    return PrCheckViolation(
      check: 'skill-frontmatter',
      message:
          '$relPath frontmatter name "$name" does not match parent directory '
          '"$parentDir".',
      remediation: 'Align `name: $parentDir` with the skill folder name.',
    );
  }
  return null;
}

List<PrCheckViolation> _checkSkillDescriptionField(
  String relPath,
  String rawFrontmatter,
  Object? rawDescription,
) {
  final desc = rawDescription is String ? rawDescription.trim() : '';
  if (desc.isEmpty) {
    return [
      PrCheckViolation(
        check: 'skill-frontmatter',
        message: '$relPath frontmatter is missing a non-empty `description`.',
        remediation:
            'Add `description: >-` with capability, "Use when ...", and '
            '"Don\'t use for ..." clauses.',
      ),
    ];
  }

  final violations = <PrCheckViolation>[];
  if (!rawFrontmatter.contains('description: >-')) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath frontmatter should use folded scalar syntax '
            '(`description: >-`).',
        remediation: 'Use `description: >-` in $relPath frontmatter.',
      ),
    );
  }
  if (desc.length > maxSkillDescriptionChars) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath description is ${desc.length} chars '
            '(exceeds $maxSkillDescriptionChars chars).',
        remediation:
            'Trim $relPath frontmatter description to <= '
            '$maxSkillDescriptionChars characters.',
      ),
    );
  }
  violations.addAll(_checkDescriptionContentRules(relPath, desc));
  return violations;
}

List<PrCheckViolation> _checkDescriptionContentRules(
  String relPath,
  String desc,
) {
  final violations = <PrCheckViolation>[];
  if (desc.contains('<') || desc.contains('>')) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath description contains XML/HTML angle brackets (< or >).',
        remediation: 'Remove `<` and `>` characters from `description`.',
      ),
    );
  }
  if (!desc.contains('Use when') && !desc.contains('Use whenever')) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath description is missing a positive "Use when ..." '
            'trigger clause.',
        remediation: 'Add a "Use when ..." sentence to `description`.',
      ),
    );
  }
  if (!desc.contains("Don't use") && !desc.contains('Do not use')) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath description is missing a negative "Don\'t use for ..." '
            'trigger clause.',
        remediation:
            'Add a "Don\'t use for ..." clause naming alternative skills.',
      ),
    );
  }
  if (desc.contains('`')) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath description contains backtick code/CLI syntax (violates '
            'progressive disclosure).',
        remediation:
            'Move CLI commands and flags out of `description` into '
            '## Quick Start.',
      ),
    );
  }
  return violations;
}

List<PrCheckViolation> _checkRelativeMarkdownLinks(
  Directory repoRoot,
  String relPath,
  List<String> lines,
) {
  final violations = <PrCheckViolation>[];
  final fileDir = p.dirname(p.join(repoRoot.path, relPath));
  _FenceState? activeFence;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final nextFence = _updateFenceState(activeFence, line);
    if (activeFence != null || nextFence != null) {
      activeFence = nextFence;
      continue;
    }
    final strippedLine = line.replaceAll(_inlineCodeSpanRegex, 'code');
    violations.addAll(
      _checkLineRelativeLinks(repoRoot, relPath, i + 1, strippedLine, fileDir),
    );
  }
  return violations;
}

List<PrCheckViolation> _checkLineRelativeLinks(
  Directory repoRoot,
  String relPath,
  int lineNumber,
  String strippedLine,
  String fileDir,
) {
  final violations = <PrCheckViolation>[];
  for (final match in _markdownLinkRegex.allMatches(strippedLine)) {
    final rawTarget = match.group(1)!.trim().split(RegExp(r'\s+')).first;
    final resolved = _resolveInternalLinkTarget(
      repoRoot.path,
      fileDir,
      rawTarget,
    );
    if (resolved == null) continue;
    if (!File(resolved).existsSync() && !Directory(resolved).existsSync()) {
      violations.add(
        PrCheckViolation(
          check: 'agent-doc-broken-link',
          message:
              '$relPath:$lineNumber links to missing internal path '
              '"$rawTarget".',
          remediation:
              'Fix the relative path "$rawTarget" or wrap placeholder links '
              'in inline backticks.',
        ),
      );
    }
  }
  return violations;
}

String? _resolveInternalLinkTarget(
  String repoRootPath,
  String fileDir,
  String rawTarget,
) {
  if (rawTarget.isEmpty ||
      rawTarget.startsWith('#') ||
      rawTarget.startsWith('//') ||
      rawTarget.startsWith('~') ||
      rawTarget.contains('://') ||
      rawTarget.startsWith('mailto:') ||
      RegExp(r'[<>${}*]').hasMatch(rawTarget)) {
    return null;
  }
  final withoutFragment = rawTarget.split('#').first.split('?').first;
  if (withoutFragment.isEmpty) return null;
  if (withoutFragment.startsWith('/')) {
    return p.normalize(p.join(repoRootPath, withoutFragment.substring(1)));
  }
  return p.normalize(p.join(fileDir, withoutFragment));
}

List<PrCheckViolation> _checkUnlinkedSkillReferences(
  Directory repoRoot,
  String skillRelPath,
  String skillText,
) {
  final skillDir = Directory(p.dirname(p.join(repoRoot.path, skillRelPath)));
  final refsDir = Directory(p.join(skillDir.path, 'references'));
  if (!refsDir.existsSync()) return const [];

  final violations = <PrCheckViolation>[];
  final refFiles = refsDir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final refFile in refFiles) {
    final refName = p.basename(refFile.path);
    if (refName.startsWith('.')) continue;
    final relRef = 'references/$refName';
    if (!skillText.contains(relRef)) {
      violations.add(
        PrCheckViolation(
          check: 'skill-unlinked-reference',
          message:
              '$skillRelPath does not link to "$relRef" in its references/ '
              'directory.',
          remediation:
              'Link [$refName]($relRef) from $skillRelPath or remove the '
              'orphaned reference file.',
        ),
      );
    }
  }
  return violations;
}
