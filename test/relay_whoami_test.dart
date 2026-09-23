import 'package:kevmoo_scripts/src/relay_whoami.dart';
import 'package:test/test.dart';

void main() {
  group('parseRelayEnvelope', () {
    test('parses standard ### <from> → <to> envelope with State and Time', () {
      const markdown = '''
### 🐧🛠️🐳 Bluefin-DX → All

- **State**: `HANDOFF` · **Time**: `2026-09-23 02:30 UTC`

- [ ] Run upkeep update
- [x] Sync skills
''';
      final env = parseRelayEnvelope(markdown, 'Fallback Title');
      expect(env.from, '🐧🛠️🐳 Bluefin-DX');
      expect(env.to, 'All');
      expect(env.stateTag, 'HANDOFF');
      expect(env.timePt, '2026-09-23 02:30 UTC');
      expect(env.todos, ['Run upkeep update']);
    });

    test('survives free-form markdown with **From:**/**To:** and missing '
        '**State**: / **Time**: (Issue #4 regression test)', () {
      const markdown = '''
## Summary

**From:** 🐧🛠️🐳 Bluefin-DX (Personal Linux · Claude Code)
**To:** ☁️🐧⚡ Enterprise Rodete, 🍎🏎️✨ Darwin Pro
**Date:** 2026-09-22

Landed PR #113 on kevmoo/scripts.dart.
- [ ] Sync skills on Enterprise Rodete
- [ ] Sync skills on Darwin Pro
''';
      final env = parseRelayEnvelope(markdown, 'Fallback Title');
      expect(env.from, '🐧🛠️🐳 Bluefin-DX (Personal Linux · Claude Code)');
      expect(env.to, '☁️🐧⚡ Enterprise Rodete, 🍎🏎️✨ Darwin Pro');
      expect(env.stateTag, 'OPEN');
      expect(env.timePt, '');
      expect(env.todos, [
        'Sync skills on Enterprise Rodete',
        'Sync skills on Darwin Pro',
      ]);
    });
  });

  group('parseRelayWhoamiArgs', () {
    test('gives prescriptive hint for bare "check" or "header"', () {
      expect(
        () => parseRelayWhoamiArgs(['check']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("Did you mean 'relay-whoami --check'?"),
          ),
        ),
      );
      expect(
        () => parseRelayWhoamiArgs(['header']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("Did you mean 'relay-whoami --header'?"),
          ),
        ),
      );
    });

    test('parses --header flags', () {
      final opts = parseRelayWhoamiArgs([
        '--header',
        '--to',
        'All',
        '--thread',
        '#4 Sync skills',
        '--state',
        'ACKED',
        '--channel',
        'oss',
        '--repo',
        'kevmoo/scripts.dart',
        '--model',
        'pro',
      ]);
      expect(opts.mode, 'header');
      expect(opts.toTarget, 'All');
      expect(opts.threadLabel, '#4 Sync skills');
      expect(opts.stateTag, 'ACKED');
      expect(opts.channel, 'oss');
      expect(opts.repoOverride, 'kevmoo/scripts.dart');
      expect(opts.modelOverride, 'pro');
    });

    test('rejects invalid --channel value', () {
      expect(
        () => parseRelayWhoamiArgs(['--check', '--channel', 'bogus']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('"bogus" is not an allowed value for option "--channel"'),
          ),
        ),
      );
    });
  });

  group('buildRelayCheckReport & mergeIssueStateMap', () {
    test('categorizes inbound, outbound, and fyi and preserves watermarks on '
        'failed channels', () {
      const rawIssue4 = RelayIssueRaw(
        number: 4,
        title: '[Sync] scripts.dart#113 skills updated',
        state: 'OPEN',
        updatedAt: '2026-09-23T02:00:00Z',
        createdAt: '2026-09-23T01:00:00Z',
        url: 'https://github.com/kevmoo/agent-relay/issues/4',
        body: '''
**From:** 🐧🛠️🐳 Bluefin-DX
**To:** ☁️🐧⚡ Enterprise Rodete, 🍎🏎️✨ Darwin Pro

- [ ] Sync skills
''',
        commentBodies: <String>[],
      );
      final selfPattern = RegExp('Enterprise Rodete|All', caseSensitive: false);
      final enriched = EnrichedRelayIssue.fromRaw(
        rawIssue4,
        channel: 'oss',
        repo: 'kevmoo/agent-relay',
        selfPattern: selfPattern,
      );
      final prevState = <String, Object?>{
        'last_sync_utc': '2026-09-22T00:00:00Z',
        'last_sync_pt': '2026-09-21 17:00 PDT',
        'corp': {
          'git_head': 'abc1234',
          'issues': <String, Object?>{
            '10': {
              'state': 'OPEN',
              'comment_count': 2,
              'updatedAt': '2026-09-22T00:00:00Z',
            },
          },
        },
        'oss': {'git_head': 'def5678', 'issues': <String, Object?>{}},
      };

      final built = buildRelayCheckReport(
        moniker: '☁️🐧⚡ Enterprise Rodete',
        lastSyncPt: '2026-09-21 17:00 PDT',
        nowUtc: '2026-09-23T02:45:00Z',
        nowPt: '2026-09-22 19:45 PDT',
        corpRepo: 'example/private-relay',
        ossRepo: 'kevmoo/agent-relay',
        corpOk: 'false',
        corpErr: 'token expired',
        ossOk: 'true',
        ossErr: '',
        newCorpSha: '',
        newOssSha: 'def5678',
        prevState: prevState,
        corpEnriched: const <EnrichedRelayIssue>[],
        ossEnriched: <EnrichedRelayIssue>[enriched],
      );

      expect(built.report, contains('NEW ISSUE [🌐 kevmoo/agent-relay] #4'));
      expect(
        built.report,
        contains(
          '=== 📥 3. Action Required — Waiting on Us '
          '(☁️🐧⚡ Enterprise Rodete) [1] ===',
        ),
      );
      expect(
        built.report,
        contains('Issue query FAILED (token expired) — watermark preserved'),
      );

      // Verify corp issue '10' watermark was preserved even though corpOk was
      // 'false', while oss issue '4' was added!
      final newCorp = built.newState['corp'] as Map<String, Object?>;
      final newCorpIssues = newCorp['issues'] as Map<String, Object?>;
      expect(newCorpIssues.containsKey('10'), isTrue);

      final newOss = built.newState['oss'] as Map<String, Object?>;
      final newOssIssues = newOss['issues'] as Map<String, Object?>;
      expect(newOssIssues.containsKey('4'), isTrue);
    });

    test('keeps multi-recipient issue in Action Required for second recipient '
        'after first recipient replies', () {
      const rawIssue5 = RelayIssueRaw(
        number: 5,
        title: '🔍 [kscripts] Review relay-whoami Dart port',
        state: 'OPEN',
        updatedAt: '2026-09-23T03:21:00Z',
        createdAt: '2026-09-23T03:03:00Z',
        url: 'https://github.com/kevmoo/agent-relay/issues/5',
        body: '''
### ☁️🐧⚡ Enterprise Rodete (`kevmoo` · `linux_x86_64`) → 🐧🛠️🐳 Bluefin-DX, 🍎🏎️✨ Darwin Pro
> **Thread**: `#5 Review` | **State**: `HANDOFF` | **Time**: `2026-09-22 20:03 PT`
''',
        commentBodies: <String>[
          '''
### 🐧🛠️🐳 Bluefin-DX (`bluefin` · `linux_x86_64`) → ☁️🐧⚡ Enterprise Rodete
> **Thread**: `#5 Review` | **State**: `ACKED` | **Time**: `2026-09-22 20:21 PT`
''',
        ],
      );

      final forDarwin = EnrichedRelayIssue.fromRaw(
        rawIssue5,
        channel: 'oss',
        repo: 'kevmoo/agent-relay',
        selfPattern: RegExp(
          'Darwin Pro|darwin-pro|gmac|All',
          caseSensitive: false,
        ),
      );
      expect(forDarwin.addressedToMe, isTrue);
      expect(forDarwin.latestFromMe, isFalse);

      final forBluefin = EnrichedRelayIssue.fromRaw(
        rawIssue5,
        channel: 'oss',
        repo: 'kevmoo/agent-relay',
        selfPattern: RegExp(
          'Bluefin-DX|bluefin-dx|bluefin|All',
          caseSensitive: false,
        ),
      );
      expect(forBluefin.addressedToMe, isFalse);
      expect(forBluefin.latestFromMe, isTrue);
    });
  });
}
