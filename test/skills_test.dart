import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/pr_check.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('co-located skills/ validation (/skill-creator invariants)', () {
    final skillsDir = Directory('skills');
    final readmeContent = File('README.md').readAsStringSync();

    test('skills directory exists and contains skill folders', () {
      check(skillsDir.existsSync()).isTrue();
      final subdirs = skillsDir.listSync().whereType<Directory>().toList();
      check(subdirs).isNotEmpty();
    });

    final skillDirs = skillsDir.existsSync()
        ? (skillsDir.listSync().whereType<Directory>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        : <Directory>[];

    for (final dir in skillDirs) {
      final folderName = p.basename(dir.path);

      test('skills/$folderName/SKILL.md satisfies /skill-creator rules', () {
        final skillFile = File(p.join(dir.path, 'SKILL.md'));
        check(
          because: 'skills/$folderName/SKILL.md must exist',
          skillFile.existsSync(),
        ).isTrue();

        final lines = skillFile.readAsLinesSync();

        // Cardinality bounds: [50, 500] lines
        check(
            because: 'SKILL.md must be between 50 and 500 lines',
            lines.length,
          )
          ..isGreaterOrEqual(50)
          ..isLessOrEqual(500);

        // Frontmatter extraction
        check(
          because: 'SKILL.md must start with YAML frontmatter ---',
          lines.first.trim(),
        ).equals('---');

        final closingIdx = lines.indexOf('---', 1);
        check(
          because: 'SKILL.md must have closing --- frontmatter delimiter',
          closingIdx,
        ).isGreaterThan(1);

        final frontmatterRaw = lines.sublist(1, closingIdx).join('\n');
        check(
          because: 'Use folded scalar (description: >-) for multi-line YAML',
          frontmatterRaw,
        ).contains('description: >-');

        final yaml = loadYaml(frontmatterRaw) as YamlMap;
        final name = yaml['name'] as String?;
        final description = yaml['description'] as String?;

        check(name).equals(folderName);
        check(description).isNotNull();

        final desc = description!.trim();
        check(
          because: 'description must be <= 1024 characters',
          desc.length,
        ).isLessOrEqual(1024);

        // No XML/HTML angle brackets inside frontmatter description
        check(
          because: 'description must not contain < or > brackets',
          desc.contains('<') || desc.contains('>'),
        ).isFalse();

        // Positive and negative trigger clauses required
        check(
          because: 'description must include "Use when" trigger guidance',
          desc,
        ).contains('Use when');
        check(
          because:
              'description must include "Don\'t use for" negative triggers',
          desc.contains("Don't use for") || desc.contains('Do not use for'),
        ).isTrue();

        // Progressive disclosure: no CLI command invocations in frontmatter
        check(
          because:
              'Frontmatter description must not leak CLI invocation syntax',
          desc.contains('`kscripts') || desc.contains('using `'),
        ).isFalse();

        // Body must include a Quick Start section
        final body = lines.sublist(closingIdx + 1).join('\n');
        check(
          because: 'Skill body should include a ## Quick Start section',
          body,
        ).contains('## Quick Start');

        // GitHub Flavored Markdown conventions (alerts + no Google3 directives)
        final mdViolations = checkGitHubMarkdownLines(
          'skills/$folderName/SKILL.md',
          lines,
        );
        check(
          because:
              'skills/$folderName/SKILL.md must follow GitHub Markdown '
              'conventions: ${mdViolations.map((v) => v.message).join('; ')}',
          mdViolations,
        ).isEmpty();

        // README.md must list every co-located skill
        check(
          because: 'README.md must link to skills/$folderName/SKILL.md',
          readmeContent,
        ).contains('skills/$folderName/SKILL.md');
      });
    }
  });
}
