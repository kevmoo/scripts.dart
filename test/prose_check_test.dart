import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/kscripts_runner.dart';
import 'package:kevmoo_scripts/src/pr_check.dart';
import 'package:kevmoo_scripts/src/prose_check.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _guillemetRegex = RegExp(r'⟦([a-z0-9-]+):\s?([^⟧]+)⟧');

typedef SmellAnchor = ({String smellId, int line, int column});

/// Strips `⟦smell-id: target⟧` markers while asserting exact 1-based
/// `(smellId, line, column)` coordinates on the resulting [ProseCheckReport].
ProseCheckReport assertProseSmells(
  String annotated, {
  String path = 'sample.md',
  ProseProfile profile = ProseProfile.auto,
  ProseFormat format = ProseFormat.auto,
  Directory? baseDir,
}) {
  final cleanBuf = StringBuffer();
  final expected = <SmellAnchor>[];
  var line = 1;
  var col = 1;
  var cursor = 0;

  void appendTracking(String chunk) {
    cleanBuf.write(chunk);
    for (var i = 0; i < chunk.length; i++) {
      if (chunk.codeUnitAt(i) == 0x0A) {
        line++;
        col = 1;
      } else {
        col++;
      }
    }
  }

  for (final m in _guillemetRegex.allMatches(annotated)) {
    appendTracking(annotated.substring(cursor, m.start));
    expected.add((smellId: m.group(1)!, line: line, column: col));
    appendTracking(m.group(2)!);
    cursor = m.end;
  }
  appendTracking(annotated.substring(cursor));

  final report = scanProseDocument(
    cleanBuf.toString(),
    path: path,
    profile: profile,
    format: format,
    baseDir: baseDir,
  );
  final actual = [
    for (final s in report.smells)
      (smellId: s.smellId, line: s.line, column: s.column),
  ]..sort(_compareAnchors);
  expected.sort(_compareAnchors);
  check(actual).deepEquals(expected);
  return report;
}

int _compareAnchors(SmellAnchor a, SmellAnchor b) {
  final byLine = a.line.compareTo(b.line);
  if (byLine != 0) return byLine;
  final byCol = a.column.compareTo(b.column);
  return byCol != 0 ? byCol : a.smellId.compareTo(b.smellId);
}

Future<({int exitCode, List<String> lines})> _runCli(
  List<String> args, {
  FutureOr<String> Function()? readStdin,
}) async {
  final lines = <String>[];
  final code = await runZoned(
    () => wrappedForTesting(() => runProseCheckCli(args, readStdin: readStdin)),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return (exitCode: code, lines: lines);
}

String _reflowMarkdown(String doc, {required int width}) {
  final out = <String>[];
  final para = <String>[];

  void flushPara() {
    if (para.isEmpty) return;
    final words = para.join(' ').trim().split(RegExp(r'\s+'));
    para.clear();
    var line = '';
    for (final w in words) {
      if (line.isEmpty) {
        line = w;
      } else if (line.length + 1 + w.length <= width) {
        line = '$line $w';
      } else {
        out.add(line);
        line = w;
      }
    }
    if (line.isNotEmpty) out.add(line);
  }

  for (final raw in doc.split('\n')) {
    final t = raw.trim();
    if (t.isEmpty ||
        t.startsWith('#') ||
        t.startsWith('|') ||
        t.startsWith('```') ||
        t.startsWith('- ')) {
      flushPara();
      if (t.startsWith('- ')) {
        final body = t.substring(2).split(RegExp(r'\s+'));
        var cur = '- ';
        for (final w in body) {
          if (cur == '- ') {
            cur = '- $w';
          } else if (cur.length + 1 + w.length <= width) {
            cur = '$cur $w';
          } else {
            out.add(cur);
            cur = '  $w';
          }
        }
        out.add(cur);
      } else {
        out.add(raw);
      }
    } else {
      para.add(t);
    }
  }
  flushPara();
  return out.join('\n');
}

void main() {
  group('parser torture cases & guillemet coordinates', () {
    test(
      '1-6: frontmatter, cross-fence comments, 4-tick fences, badges, tables',
      () {
        assertProseSmells('''
---
title: Sample Spec
status: draft
---
<!--
multi-line comment before content
-->
[![Build](https://img.shields.io/badge.svg)](https://github.com/org/pkg/actions)

````markdown
```dart
// <!-- comment start inside code fence
final x = 'a — b';
```
````

Between fences we catch ⟦nested-parens: (outer (inner) aside)⟧ cleanly.

```dart
// comment end -->
```

Use `Decoder`, `markdown`, `octet`, and ``foo `a — b` bar`` across
[Wiki](https://en.wikipedia.org/wiki/Dart_(programming_language) "Dart Wiki"),
lib/src/runner.dart, and `a`/`b`/`c`.

| Col A | Col B | Col C |
| :--- | :--- | :--- |
| ``foo`` | bar | ``baz`` |
| `x \\| y` | ok | `z` |

Final line has a real prose ⟦prose-em-dash: —⟧ dash.
''');
      },
    );

    test(
      '7-8: sentence wrappers, standalone parens, abbreviations, decimals',
      () {
        final report = assertProseSmells(
          'He said "keep sentences short." (Standalone paren sentence.) '
          'We support flags, configs, etc. However, we also check Fig. 1, '
          'U.S. rules, J. R. Smith, Wait... what, steps: 1. parse, 2. lint, '
          'and .dart files in v3.12.0.[^1]\n\n'
          '[^1]: Footnote body with (extra (nested) parens) ignored as def.\n',
        );
        check(report.stats.sentenceCount).equals(4);
      },
    );

    test('9: month-prefix identifiers vs real date/numeric backticks & plurals', () {
      assertProseSmells(
        'Keep `Decoder`, `markdown`, `octet`, `janitor`, and `mayo` clean.\n\n'
        'Flag ⟦numeric-backtick: `Nov 2026`⟧, '
        '⟦numeric-backtick: `Jan 15, 2026`⟧, '
        '⟦numeric-backtick: `2026-11-19`⟧, '
        '⟦numeric-backtick: `+61 KB`⟧, and '
        '⟦code-span-plural: `Widget`s⟧.\n',
      );
    });

    test(
      '10-12: ref defs, data URIs, SPOT blocks, details, task lists, code',
      () {
        const spotTag = 'SPOT';
        final dataUri = '<data:image/png;base64,${'A' * 512}>';
        final report = assertProseSmells('''
Short clean sentence.

&nbsp;

<!-- BEGIN $spotTag: demo-id -->
Stamped canonical prose — with (nested (parens)) ignored here.
<!-- END $spotTag: demo-id -->

<details>
<summary>Raw trace</summary>
Stack line — with ; semicolons ; and (nested (parens)).
</details>

    // 4-space indented code block in markdown mode
    final code = `2026-11-19` — ignored;

- [x] **Task Lead ⟦bold-lead-paren: (qualifier)⟧**: Active bullet item.

[ref-id]: https://example.com/very/long/path "Reference Title Words Ignored"
[img-id]: $dataUri
''');
        check(report.stats.proseWords).equals(6);
      },
    );

    test('13: escaped tilde ranges and slash-jargon chains', () {
      assertProseSmells(
        'Models achieve ~54% Pass@1 on benchmarks today.\n\n'
        'The runtime leaves an ⟦uncited-tilde-range: illustrative \\~10%–15%⟧ '
        'browser wedge.\n\n'
        'Cited [study](https://example.com) reports '
        '⟦uncited-tilde-range: ~10%–15%⟧ lift.\n\n'
        'Compare declarative ⟦slash-jargon-chain: layout/vector/shader⟧ '
        'primitives alongside HTML/CSS/JS and src/prose_check.dart.\n',
      );
    });
  });

  group('--format=text plain-text mode', () {
    test(
      'analyzes 4-space indented paragraphs in text mode and .txt paths',
      () {
        const indentedText =
            '    Indented plain text paragraph with a prose '
            '⟦prose-em-dash: —⟧ dash.\n';
        final viaFlag = assertProseSmells(
          indentedText,
          format: ProseFormat.text,
        );
        check(viaFlag.format).equals(ProseFormat.text);
        check(viaFlag.stats.proseWords).equals(8);

        final viaExt = assertProseSmells(indentedText, path: 'notes.txt');
        check(viaExt.format).equals(ProseFormat.text);
      },
    );
  });

  group('calibrated prose smells & profile tuning', () {
    test('paired em-dash, semicolon chain, parens, and citation crutches', () {
      assertProseSmells(
        'We track 7DA (7-day active) and 28DA (28-day active) users daily.\n\n'
        '#### Subheading ⟦paired-em-dash: —⟧with aside—here\n\n'
        'Workflows⟦paired-em-dash: —⟧including proxies—ship built in.\n\n'
        'First we start the server⟦prose-semicolon-chain: ;⟧ second we proxy; '
        'third we bundle.\n\n'
        '⟦multi-paren-sentence: Users⟧ '
        '⟦long-or-clause-paren: (filtered across all seven active public '
        'release channels)⟧ and bots '
        '⟦long-or-clause-paren: (which generate heavy synthetic load daily)⟧ '
        'spike traffic.\n\n'
        'Check details ⟦compound-citation-paren: (see src/runner.dart)⟧ and '
        'metrics ⟦compound-citation-paren: (alpha; beta)⟧.\n',
      );
    });

    test(
      'long-sentence, code-pill-soup, bloated-table-cell, and micro-tables',
      () {
        final words46 = List.generate(46, (i) => 'word$i').join(' ');
        final cell40 = List.generate(40, (i) => 'cell$i').join(' ');
        const soup =
            'Configure `a`, `b`, `c`, `d`, `e`, `f`, `g`, `h`, and `i` '
            'across every single active local package workspace directory '
            'during continuous integration preflight validation runs today.';

        final report = scanProseDocument('''
| Author | Team |
| :--- | :--- |
| Alice | Core |

$words46.

$soup

| Tool | Role |
| :--- | :--- |
| foo | bar |

| Flag | Mode |
| :--- | :--- |
| --a | $cell40 |
''');
        check(report.totalSmellCountsById.keys)
          ..contains('long-sentence')
          ..contains('code-pill-soup')
          ..contains('bloated-table-cell')
          ..contains('micro-table-fragmentation');
      },
    );

    test('readme vs narrative vs spec profile adjustments', () {
      const sample = '''
- **Flag (`--json`)**: Emits status `78` — compact output.
''';
      final readmeRep = scanProseDocument(sample, path: 'README.md');
      check(readmeRep.profile).equals(ProseProfile.readme);
      check(readmeRep.totalSmellCountsById.containsKey('bold-lead-paren'))
          .isFalse;
      check(readmeRep.totalSmellCountsById.containsKey('numeric-backtick'))
          .isFalse;
      check(readmeRep.smells.single.smellId).equals('prose-em-dash');
      check(readmeRep.smells.single.severity).equals(SmellSeverity.info);

      final specRep = scanProseDocument(sample, path: 'feature_prd.md');
      check(specRep.profile).equals(ProseProfile.spec);
      check(specRep.totalSmellCountsById.keys)
        ..contains('bold-lead-paren')
        ..contains('numeric-backtick')
        ..contains('prose-em-dash');

      // Narrative vs readme pill density on 330-word prose (~13.3 pills/100w).
      final para = List.generate(
        22,
        (i) =>
            'Sentence $i invokes `cmd_$i` and `opt_$i` during standard '
            'execution across local developer environments without issues.',
      ).join(' ');
      final narrativeDensity = scanProseDocument(
        para,
        path: 'product_strategy.md',
      );
      check(narrativeDensity.profile).equals(ProseProfile.narrative);
      check(narrativeDensity.totalSmellCountsById.keys)
          .contains('doc-pill-density');

      final readmeDensity = scanProseDocument(para, path: 'README.md');
      check(readmeDensity.totalSmellCountsById.containsKey('doc-pill-density'))
          .isFalse;
    });

    test(
      'document-level aggregates: wall-of-bold, run-on-share, paren-share',
      () {
        final bullets = List.generate(
          16,
          (i) =>
              '- **Topic $i**: Detailed thirty-two word explanation sentence '
              'number $i describing cross-platform runtime scheduling '
              '(including background queue prioritization rules) across '
              'desktop and mobile targets cleanly every single day for teams.',
        ).join('\n');
        final report = scanProseDocument(bullets, path: 'vision_memo.md');
        check(report.totalSmellCountsById.keys)
          ..contains('wall-of-bold')
          ..contains('run-on-share')
          ..contains('paren-word-share');
      },
    );

    test('link hygiene: unportable file:/// URIs and broken local links', () {
      final tempDir = Directory.systemTemp.createTempSync('prose_check_links_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final existing = File(p.join(tempDir.path, 'exists.md'))
        ..writeAsStringSync('# Exists\n');

      final doc =
          'Valid relative [exists](exists.md#top), '
          'missing relative [dead](missing.md), '
          'valid file [local](file://${existing.path}), and '
          'missing file [gone](file://${tempDir.path}/nope.md).\n';
      final report = scanProseDocument(doc, baseDir: tempDir);
      check(report.totalSmellCountsById['unportable-file-uri']).equals(2);
      check(report.totalSmellCountsById['broken-local-link']).equals(2);
    });
  });

  group('CLI contract, exit codes, stdin, directory walk, and --json', () {
    test('advisory exit 0 by default vs --fail-on-smells exit 1', () async {
      const highDoc = 'Nested (outer (inner)) parens in prose.\n';
      final advisory = await _runCli(['-'], readStdin: () => highDoc);
      check(advisory.exitCode).equals(0);
      check(advisory.lines.join('\n')).contains('nested-parens');

      final strict = await _runCli([
        '--fail-on-smells',
        '-',
      ], readStdin: () => highDoc);
      check(strict.exitCode).equals(1);

      const onlySmellDoc = 'Isolated prose — dash without high smells.\n';
      final strictLow = await _runCli([
        '--fail-on-smells',
        '-',
      ], readStdin: () => onlySmellDoc);
      check(strictLow.exitCode).equals(0);
    });

    test(
      'compact --json schema, --top cap, and totalSmellCountsById',
      () async {
        const noisyDoc =
            'Line 1 (a (b)) nested.\n\n'
            'Line 3 (c (d)) nested.\n\n'
            'Line 5—paired—dash.\n\n'
            'Line 7 prose — dash.\n';
        final res = await _runCli([
          '--json',
          '--top=2',
          '-',
        ], readStdin: () => noisyDoc);
        check(res.exitCode).equals(0);
        final decoded = jsonDecode(res.lines.single) as Map<String, Object?>;
        check(decoded['totalSmellCount']).equals(4);
        check(decoded['highSmellCount']).equals(3);

        final fileObj =
            (decoded['files'] as List<Object?>).single as Map<String, Object?>;
        check(fileObj['path']).equals('<stdin>');
        check(fileObj['truncatedSmells']).equals(2);
        final counts = fileObj['totalSmellCountsById'] as Map<String, Object?>;
        check(counts['nested-parens']).equals(2);
        check(counts['paired-em-dash']).equals(1);
        check(counts['prose-em-dash']).equals(1);

        final smells = fileObj['smells'] as List<Object?>;
        check(smells.length).equals(2);
        final stats = fileObj['stats'] as Map<String, Object?>;
        check(stats.keys)
          ..contains('proseWords')
          ..contains('estimatedReadMinutes')
          ..contains('sentenceMeanWords')
          ..contains('sentenceP90Words')
          ..contains('pctOver30Words')
          ..contains('pctWordsInParens')
          ..contains('pillsPer100Words')
          ..contains('boldLeadPct');
      },
    );

    test(
      'usage (64), missing file (66), help first line, and dir walk',
      () async {
        final help = await _runCli(['--help']);
        check(help.exitCode).equals(0);
        check(help.lines.first.split('\n').first).equals(proseCheckDescription);

        final noArgs = await _runCli([]);
        check(noArgs.exitCode).equals(ExitCode.usage.code);

        final badTop = await _runCli(['--top=-1', '-']);
        check(badTop.exitCode).equals(ExitCode.usage.code);

        final missing = await _runCli(['/nonexistent/prose_check_target.md']);
        check(missing.exitCode).equals(ExitCode.noInput.code);

        final tempDir = Directory.systemTemp.createTempSync('prose_walk_');
        addTearDown(() => tempDir.deleteSync(recursive: true));
        File(p.join(tempDir.path, 'guide.md'))
            .writeAsStringSync('Clean short guide sentence.\n');
        File(p.join(tempDir.path, 'CHANGELOG.md'))
            .writeAsStringSync('- `2026-11-19` (outer (inner)).\n');
        File(p.join(tempDir.path, 'AGENTS.md'))
            .writeAsStringSync('- **Rule (a)**: (outer (inner)).\n');
        Directory(p.join(tempDir.path, 'node_modules')).createSync();
        File(p.join(tempDir.path, 'node_modules', 'pkg.md'))
            .writeAsStringSync('Ignored (outer (inner)).\n');

        final walk = await _runCli(['--json', tempDir.path]);
        check(walk.exitCode).equals(0);
        final files =
            (jsonDecode(walk.lines.single) as Map<String, Object?>)['files']
                as List<Object?>;
        check(files.length).equals(1);

        for (final alias in [
          'prose',
          'prose-review',
          'doc-audit',
          'doc-smells',
        ]) {
          check(commonKScriptMistakes[alias]).equals('prose-check');
        }
      },
    );
  });

  group('property invariants & public-repo diode safety', () {
    test('Property 1: 1:1 length and CR/LF offset preservation on mask buffer', () {
      const fragments = <String>[
        '---\ntitle: 🚀 Rocket\n---\n',
        'Plain emoji 🧪👩‍💻 line with prose.\n',
        '<!-- multi\nline 🚀\ncomment -->\n',
        '````md\n```dart\nfinal s = "🚀";\n```\n````\n',
        '<!-- BEGIN SPOT: x -->\n🚀 inner\n<!-- END SPOT: x -->\n',
        'Inline ``code `🚀` span`` and `Widget`s here.\n',
        '[![Badge 🚀](https://example.com/a.svg)](https://example.com/b_(1))\n',
        '[ref]: https://example.com/🚀 "Title"\n',
      ];
      for (var maskBits = 0; maskBits < 32; maskBits++) {
        final sep = maskBits.isOdd ? '\r\n' : '\n';
        final buf = StringBuffer();
        for (var i = 0; i < fragments.length; i++) {
          if ((maskBits & (1 << (i % 5))) != 0) {
            buf.write(fragments[i].replaceAll('\n', sep));
          }
        }
        final raw = buf.toString();
        final masked = debugMaskMarkdown(raw);
        check(masked.length).equals(raw.length);
        for (var idx = 0; idx < raw.length; idx++) {
          check(masked.codeUnitAt(idx) == 0x0A)
              .equals(raw.codeUnitAt(idx) == 0x0A);
          check(masked.codeUnitAt(idx) == 0x0D)
              .equals(raw.codeUnitAt(idx) == 0x0D);
        }
      }
    });

    test('Property 2: 80-column vs 120-column reflow idempotence', () {
      const source = '''
# Architecture Overview

Modern command-line tools benefit from fast deterministic feedback loops (especially when developers iterate across multiple packages) without adding external runtime dependencies.

- ** Core Execution **: Evaluates syntax boundaries using `scanProseDocument` and [design notes](https://example.com/spec) across wrapped lines; avoids brittle heuristics.
- ** Output Modes (`--json`) **: Emits structured counts and hotspot excerpts — keeping terminal summaries scannable for authors.

| Mode | Latency | Output |
| :--- | :--- | :--- |
| json | fast | compact |
| text | fast | human |
''';
      final wrapped80 = _reflowMarkdown(source, width: 80);
      final wrapped120 = _reflowMarkdown(source, width: 120);
      check(wrapped80 == wrapped120).isFalse;

      final r80 = scanProseDocument(wrapped80);
      final r120 = scanProseDocument(wrapped120);
      check(r80.stats.proseWords).equals(r120.stats.proseWords);
      check(r80.stats.sentenceCount).equals(r120.stats.sentenceCount);
      check(r80.stats.pctWordsInParens).equals(r120.stats.pctWordsInParens);
      check(r80.totalSmellCountsById).deepEquals(r120.totalSmellCountsById);
      check([for (final s in r80.smells) s.smellId])
          .deepEquals([for (final s in r120.smells) s.smellId]);
    });

    test(
      'owned prose-check files contain zero internal/corporate literals',
      () {
        const ownedPaths = [
          'bin/prose_check.dart',
          'lib/src/prose_check.dart',
          'lib/src/prose_check/prose_extractor.dart',
          'lib/src/prose_check/prose_masker.dart',
          'lib/src/prose_check/prose_smells.dart',
          'test/prose_check_test.dart',
        ];
        for (final rel in ownedPaths) {
          final lines = File(rel).readAsLinesSync();
          final violations = checkRawMarkdownDiodeAndSpot(rel, lines);
          check(
            because:
                '$rel must be 100% diode-clean: '
                '${violations.map((v) => v.message).join("; ")}',
            violations,
          ).isEmpty;
        }
      },
    );
  });

  group(
    'Round-2 exported callouts, escapes, link slugs, and readme tuples',
    () {
      test('extracts prose and smells inside 1-column callout pipe boxes', () {
        final report = assertProseSmells(
          '| Callout with ⟦nested-parens: (outer (inner))⟧ parens. |\n'
          '| :--- |\n',
        );
        check(report.stats.proseWords).equals(5);
        check(report.stats.tableCount).equals(0);
      });

      test(
        'unescapes exported build\\_runner and C\\# without splitting words',
        () {
          final escaped = assertProseSmells(
            'Run build\\_runner and C\\# tools cleanly.\n',
          );
          final plain = scanProseDocument(
            'Run build_runner and C# tools cleanly.\n',
          );
          check(escaped.stats.proseWords).equals(plain.stats.proseWords);
          check(escaped.stats.proseWords).equals(6);
        },
      );

      test(
        'exempts HTML/CSS/SVG/JS and single-token link-label slash slugs',
        () {
          assertProseSmells(
            'Render HTML/CSS/SVG/JS widgets across '
            '[org/repo](https://example.com/a), '
            '[alpha/beta/gamma](https://example.com/b), and '
            '[core/sdk](https://example.com/c) while catching '
            '⟦slash-jargon-chain: layout/vector/shader⟧ in prose.\n',
          );
        },
      );

      test('exempts readme type/default config tuples with semicolons', () {
        final readmeRep = assertProseSmells(
          '- `cleanBranches` (`bool`, default `true`; `false` when '
          '`allowWorktree: true`): Skip branch cleanup.\n',
          path: 'README.md',
        );
        check(readmeRep.profile).equals(ProseProfile.readme);
        check(readmeRep.smells).isEmpty;

        final specRep = scanProseDocument(
          '- `cleanBranches` (`bool`, default `true`; `false` when '
          '`allowWorktree: true`): Skip branch cleanup.\n',
          path: 'design_spec.md',
        );
        check(specRep.totalSmellCountsById.keys)
            .contains('compound-citation-paren');
      });
    },
  );
}
