part of 'pr_check.dart';

/// Maximum character count (~6,250 tokens) allowed for a `SKILL.md` file before
/// progressive disclosure into `references/*.md` is required.
const maxSkillMdChars = 25000;

/// Maximum character count (~3,750 tokens) allowed for always-on instruction
/// files (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`).
const maxAgentsMdChars = 15000;

/// Maximum character length for a `SKILL.md` YAML `description` field.
const maxSkillDescriptionChars = 1024;

const _alwaysOnAgentDocNames = {'AGENTS.md', 'CLAUDE.md', 'GEMINI.md'};

final _inlineCodeSpanRegex = RegExp(r'(`+)(.+?)\1');
final _inlineCliFlagUnicodeDashRegex = RegExp(
  r'(?:^|\s)[\u2014\u2013][A-Za-z0-9]',
);
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

final class _MarkdownAstCollector implements md.NodeVisitor {
  final List<String> hrefs = [];
  final List<String> inlineCodes = [];

  @override
  void visitText(md.Text text) {}

  @override
  bool visitElementBefore(md.Element element) {
    if (element.tag == 'a') {
      final href = element.attributes['href'];
      if (href != null) hrefs.add(href);
    } else if (element.tag == 'pre') {
      return false;
    } else if (element.tag == 'code') {
      inlineCodes.add(element.textContent);
    }
    return true;
  }

  @override
  void visitElementAfter(md.Element element) {}
}

_MarkdownAstCollector _collectMarkdownAst(List<String> lines) {
  var bodyLines = lines;
  if (lines.isNotEmpty && lines.first.trim() == '---') {
    final closeIdx = lines.indexOf('---', 1);
    if (closeIdx > 0) {
      bodyLines = lines.sublist(closeIdx + 1);
    }
  }
  final doc = md.Document(extensionSet: md.ExtensionSet.gitHubWeb);
  final collector = _MarkdownAstCollector();
  for (final node in doc.parseLines(bodyLines)) {
    node.accept(collector);
  }
  return collector;
}

List<PrCheckViolation> _checkAstInlineCliFlagDashes(
  String relPath,
  List<String> lines,
) {
  final violations = <PrCheckViolation>[];
  final collector = _collectMarkdownAst(lines);
  for (final span in collector.inlineCodes) {
    if (_inlineCliFlagUnicodeDashRegex.hasMatch(span)) {
      violations.add(
        PrCheckViolation(
          check: 'markdown-code-unicode-dash',
          message:
              '$relPath contains a Unicode dash flag prefix inside '
              'inline code (`$span`).',
          remediation: 'Replace — or – with ASCII -- or - in CLI flags.',
        ),
      );
    }
  }
  return violations;
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
/// `GEMINI.md`, and `references/*.md`) for line budgets, frontmatter contracts,
/// and internal link integrity.
List<PrCheckViolation> checkAgentDocFiles(
  Directory repoRoot,
  List<String> changedFiles,
) {
  final violations = <PrCheckViolation>[];
  for (final relPath in changedFiles.where(_isAgentDocPath)) {
    violations.addAll(checkSingleAgentDocFile(repoRoot, relPath));
  }
  return violations;
}

/// Validates a single agent documentation file at [relPath] relative to
/// [repoRoot].
List<PrCheckViolation> checkSingleAgentDocFile(
  Directory repoRoot,
  String relPath,
) {
  final file = File(p.join(repoRoot.path, relPath));
  if (!file.existsSync()) return const [];

  final text = file.readAsStringSync();
  final lines = file.readAsLinesSync();
  final base = p.basename(relPath);
  final violations = <PrCheckViolation>[];

  if (base == 'SKILL.md') {
    violations.addAll(_checkSkillMdFile(repoRoot, relPath, text, lines));
  } else if (_alwaysOnAgentDocNames.contains(base)) {
    violations.addAll(_checkAlwaysOnAgentDoc(relPath, text));
  }

  violations.addAll(_checkMarkdownAstLinks(repoRoot, relPath, lines));
  return violations;
}

List<PrCheckViolation> _checkAlwaysOnAgentDoc(String relPath, String text) {
  if (text.length <= maxAgentsMdChars) return const [];
  final approxTokens = text.length ~/ 4;
  const maxTokens = maxAgentsMdChars ~/ 4;
  return [
    PrCheckViolation(
      check: 'agent-doc-char-budget',
      message:
          '$relPath is ${text.length} chars (~$approxTokens tokens), '
          'exceeding the $maxAgentsMdChars-char (~$maxTokens-token) '
          'always-on instruction budget.',
      remediation:
          'Extract detailed reference tables or multi-step playbooks into '
          'on-demand skills or `references/*.md` files so $relPath stays '
          '<= $maxAgentsMdChars chars with zero content loss.',
    ),
  ];
}

List<PrCheckViolation> _checkSkillMdFile(
  Directory repoRoot,
  String relPath,
  String text,
  List<String> lines,
) {
  final violations = <PrCheckViolation>[];
  if (text.length > maxSkillMdChars) {
    final approxTokens = text.length ~/ 4;
    const maxTokens = maxSkillMdChars ~/ 4;
    violations.add(
      PrCheckViolation(
        check: 'agent-doc-char-budget',
        message:
            '$relPath is ${text.length} chars (~$approxTokens tokens), '
            'exceeding the $maxSkillMdChars-char (~$maxTokens-token) '
            'SKILL.md budget.',
        remediation:
            'Extract reference schemas, long templates, or edge-case matrices '
            'into `references/*.md` (linked from $relPath) so $relPath stays '
            '<= $maxSkillMdChars chars with zero content loss.',
      ),
    );
  }
  violations
    ..addAll(_checkSkillFrontmatter(relPath, lines))
    ..addAll(_checkUnlinkedSkillReferences(repoRoot, relPath, text));
  return violations;
}

List<PrCheckViolation> _checkSkillFrontmatter(
  String relPath,
  List<String> lines,
) {
  if (lines.isEmpty || lines.first.trim() != '---') {
    return [
      PrCheckViolation(
        check: 'skill-frontmatter',
        message: '$relPath must start with YAML frontmatter (`---`).',
        remediation:
            'Add a `---` YAML frontmatter block with `name` and '
            '`description` at the top of $relPath.',
      ),
    ];
  }
  final closingIdx = lines.indexOf('---', 1);
  if (closingIdx <= 1) {
    return [
      PrCheckViolation(
        check: 'skill-frontmatter',
        message: '$relPath has an unterminated YAML frontmatter block.',
        remediation: 'Close the YAML frontmatter block with `---`.',
      ),
    ];
  }

  final rawFrontmatter = lines.sublist(1, closingIdx).join('\n');
  final YamlMap yaml;
  try {
    final parsed = loadYaml(rawFrontmatter);
    if (parsed is! YamlMap) {
      return [
        PrCheckViolation(
          check: 'skill-frontmatter',
          message: '$relPath YAML frontmatter is not a key-value map.',
          remediation: 'Define `name` and `description` keys in frontmatter.',
        ),
      ];
    }
    yaml = parsed;
  } on YamlException catch (e) {
    return [
      PrCheckViolation(
        check: 'skill-frontmatter',
        message: '$relPath has invalid YAML frontmatter: ${e.message}',
        remediation: 'Fix YAML syntax in $relPath frontmatter.',
      ),
    ];
  }

  return _validateSkillMetadata(relPath, yaml);
}

List<PrCheckViolation> _validateSkillMetadata(String relPath, YamlMap yaml) {
  final violations = <PrCheckViolation>[];
  final parentFolder = p.basename(p.dirname(relPath));
  final name = yaml['name']?.toString().trim() ?? '';

  if (name.isEmpty || !_skillNamePattern.hasMatch(name)) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath frontmatter `name` ("$name") must match `^[a-z0-9-]+\$`.',
        remediation: 'Set `name: $parentFolder` in $relPath.',
      ),
    );
  } else if (parentFolder != '.' && name != parentFolder) {
    violations.add(
      PrCheckViolation(
        check: 'skill-frontmatter',
        message:
            '$relPath frontmatter `name` ("$name") does not match parent '
            'directory "$parentFolder".',
        remediation: 'Set `name: $parentFolder` in $relPath.',
      ),
    );
  }

  violations.addAll(
    _validateSkillDescription(
      relPath,
      yaml['description']?.toString().trim() ?? '',
    ),
  );
  return violations;
}

List<PrCheckViolation> _validateSkillDescription(String relPath, String desc) {
  if (desc.isEmpty) {
    return [
      PrCheckViolation(
        check: 'skill-frontmatter',
        message: '$relPath frontmatter is missing a `description` field.',
        remediation:
            'Add a `description: >-` field with capability and trigger '
            'clauses.',
      ),
    ];
  }

  final violations = <PrCheckViolation>[];
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
  return violations;
}

List<PrCheckViolation> _checkMarkdownAstLinks(
  Directory repoRoot,
  String relPath,
  List<String> lines,
) {
  final violations = <PrCheckViolation>[];
  final fileDir = p.dirname(p.join(repoRoot.path, relPath));
  final collector = _collectMarkdownAst(lines);

  for (final rawHref in collector.hrefs) {
    final resolved = _resolveInternalLinkTarget(
      repoRoot.path,
      fileDir,
      rawHref,
    );
    if (resolved == null) continue;
    if (!File(resolved).existsSync() && !Directory(resolved).existsSync()) {
      violations.add(
        PrCheckViolation(
          check: 'agent-doc-broken-link',
          message: '$relPath links to missing internal path "$rawHref".',
          remediation:
              'Fix the relative path "$rawHref" or wrap placeholder links '
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
  String rawHref,
) {
  final href = Uri.decodeFull(rawHref.trim());
  if (_isIgnoredLinkHref(href)) return null;
  final withoutFragment = href.split('#').first.split('?').first;
  if (withoutFragment.isEmpty) return null;
  final resolved = withoutFragment.startsWith('/')
      ? p.normalize(p.join(repoRootPath, withoutFragment.substring(1)))
      : p.normalize(p.join(fileDir, withoutFragment));
  if (resolved != repoRootPath && !p.isWithin(repoRootPath, resolved)) {
    return null;
  }
  return resolved;
}

bool _isIgnoredLinkHref(String href) =>
    href.isEmpty ||
    href == '...' ||
    href.startsWith('#') ||
    href.startsWith('//') ||
    href.startsWith('~') ||
    href.contains('://') ||
    href.startsWith('mailto:') ||
    href.startsWith('javascript:') ||
    href.startsWith('data:') ||
    RegExp(r'^/\d{4}/\d{2}/').hasMatch(href) ||
    RegExp(r'[<>${}*]').hasMatch(href);

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
