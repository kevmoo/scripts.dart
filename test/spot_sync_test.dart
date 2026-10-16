@TestOn('vm')
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/pr_check.dart';
import 'package:kevmoo_scripts/src/shared/spot_sync.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('spot_sync_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('canonicalizeSpotMarkdown & checkSpotBlocksInLines', () {
    const sampleDefs = {
      'dart-sample-rule':
          '- **Core Principle**: Prefer the boundary the language compiler '
          'enforces\n'
          '  (library privacy + class modifiers) over one an annotation '
          'suggests.\n'
          '- **Second Bullet**: Keep helper functions pure and '
          'deterministic.',
    };

    test(
      'treats Prettier line-wrapping at indent 0, 2, and 4 as identical',
      () {
        final indentedReflowedLines = [
          '# Sample Rubric',
          '',
          '1. **Parent Section**:',
          '',
          '   <!-- BEGIN SPOT: dart-sample-rule -->',
          '',
          '   - **Core Principle**: Prefer the boundary the language',
          '     compiler enforces (library privacy + class modifiers)',
          '     over one an annotation suggests.',
          '   - **Second Bullet**: Keep helper functions pure and',
          '     deterministic.',
          '',
          '   <!-- END SPOT: dart-sample-rule -->',
        ];

        final issues = checkSpotBlocksInLines(
          'skills/pr-review/RUBRIC.md',
          indentedReflowedLines,
          canonicalDefs: sampleDefs,
        );
        check(issues).isEmpty();
      },
    );

    test(
      'flags content drift, unknown IDs, empty blocks, and unbalanced markers',
      () {
        final driftedLines = [
          '<!-- BEGIN SPOT: dart-sample-rule -->',
          '- **Core Principle**: Mutated wording that drifts from SPOT_DEF.',
          '<!-- END SPOT: dart-sample-rule -->',
          '',
          '<!-- BEGIN SPOT: nonexistent-id -->',
          '- Some content.',
          '<!-- END SPOT: nonexistent-id -->',
          '',
          '<!-- BEGIN SPOT: dart-sample-rule -->',
          '<!-- END SPOT: dart-sample-rule -->',
          '',
          '<!-- END SPOT: stray-end -->',
          '<!-- BEGIN SPOT: dart-sample-rule -->',
        ];

        final issues = checkSpotBlocksInLines(
          'skills/sample/SKILL.md',
          driftedLines,
          canonicalDefs: sampleDefs,
        );
        check(issues.map((i) => i.kind).toList()).deepEquals([
          'spot-content-drift',
          'spot-unknown-id',
          'spot-empty-block',
          'spot-unmatched-end',
          'spot-unclosed-begin',
        ]);
      },
    );

    test('stampSpotBlocksInText preserves marker indentation and '
        'applyRepoSpotStamping rejects ~/.agents/skills targets', () {
      const input = '''
# Doc

  <!-- BEGIN SPOT: dart-sample-rule -->
  <!-- END SPOT: dart-sample-rule -->
''';
      final stamped = stampSpotBlocksInText(input, sampleDefs);
      check(stamped)
        ..contains('  <!-- BEGIN SPOT: dart-sample-rule -->')
        ..contains('  - **Core Principle**:')
        ..contains('  <!-- END SPOT: dart-sample-rule -->');
      check(
        checkSpotBlocksInLines(
          'doc.md',
          stamped.split('\n'),
          canonicalDefs: sampleDefs,
        ),
      ).isEmpty();

      final badTarget = Directory(
        p.join(tempDir.path, '.agents', 'skills', 'pr-review'),
      )..createSync(recursive: true);
      check(
        () => applyRepoSpotStamping(
          badTarget,
          canonicalDefs: sampleDefs,
          runPrettier: false,
        ),
      ).throws<ArgumentError>();
    });
  });

  group('Two-Tier Raw-Line Corp & Portability Diode', () {
    test('flags Tier 1 corp tokens in prose, inline code, and fenced blocks '
        'while allowing lowercase English "critique"', () {
      final violations = checkRawMarkdownDiodeAndSpot(
        'skills/sample/SKILL.md',
        [
          '# Sample Skill',
          '',
          'Understand and critique the architecture before editing.',
          'Never reference `cl/123456` or `/google/src/cloud/user/ws` here.',
          '```bash',
          'blaze-for-agents test //depot/foo:bar',
          '```',
          'Or post to Critique and Buganizer (`b/987654`).',
        ],
        canonicalSpotDefs: const {},
      );

      check(violations.map((v) => v.check).toList()).deepEquals([
        'corp-internal-literal',
        'corp-internal-literal',
        'corp-internal-literal',
      ]);
    });

    test('flags Tier 2 machine-local paths (`~/.agents/`, `/home/kevmoo/`) '
        'inside skills/** and broken ~/ or // links', () {
      final skillDir = Directory(p.join(tempDir.path, 'skills', 'my-skill'))
        ..createSync(recursive: true);
      final skillFile = File(p.join(skillDir.path, 'SKILL.md'))
        ..writeAsStringSync('''
---
name: my-skill
description: >-
  Validates skill portability. Use when testing skills. Don't use for other
  tasks.
---

# My Skill

Read `~/.agents/CODING_STANDARDS.md` and [local](~/.agents/CODING_STANDARDS.md)
or [depot](//depot/google3/foo.md).
''');

      final violations = checkSingleAgentDocFile(
        tempDir,
        p.relative(skillFile.path, from: tempDir.path),
        canonicalSpotDefs: const {},
      );
      final checks = violations.map((v) => v.check).toList();
      check(checks)
        ..contains('skill-unportable-local-path')
        ..contains('agent-doc-broken-link');
    });
  });
}
