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

    test('surfaces CLOSED issues with actionable post-close replies and '
        'badges SETTLING / SETTLED DONE threads', () {
      final selfPattern = RegExp('Enterprise Rodete|All', caseSensitive: false);

      // 1. Closed issue #10 with a post-close reply (like the 38s race on #10).
      const closedWithPostCloseReply = RelayIssueRaw(
        number: 10,
        title: '🔁 [review-queue] kevmoo/gcp-http-bench #4 #6 #5',
        state: 'CLOSED',
        updatedAt: '2026-09-26T03:04:06Z',
        createdAt: '2026-09-26T02:35:00Z',
        closedAt: '2026-09-26T03:03:29Z',
        url: 'https://github.com/kevmoo/agent-relay/issues/10',
        body: '''
### 🐧🛠️🐳 Bluefin-DX → ☁️🐧⚡ Enterprise Rodete
> **State**: `HANDOFF` | **Time**: `2026-09-25 19:35 PT`
''',
        commentBodies: <String>[
          '''
### ☁️🐧⚡ Enterprise Rodete → 🐧🛠️🐳 Bluefin-DX
> **State**: `DONE` | **Time**: `2026-09-25 20:03 PT`
''',
          '''
### 🐧🛠️🐳 Bluefin-DX → ☁️🐧⚡ Enterprise Rodete
> **State**: `ACKED` | **Time**: `2026-09-25 20:04 PT`
''',
        ],
        lastCommentCreatedAt: '2026-09-26T03:04:06Z',
      );

      // 2. Historical closed issue #1 with an already-synced ACKED post-close
      // comment (should NOT re-trigger Action Required).
      const historicalClosedAcked = RelayIssueRaw(
        number: 1,
        title: '👋 Hello from Bluefin-DX',
        state: 'CLOSED',
        updatedAt: '2026-09-19T21:56:45Z',
        createdAt: '2026-09-19T21:00:00Z',
        closedAt: '2026-09-19T21:37:31Z',
        url: 'https://github.com/kevmoo/agent-relay/issues/1',
        body: '''
### 🐧🛠️🐳 Bluefin-DX → ☁️🐧⚡ Enterprise Rodete
> **State**: `OPEN` | **Time**: `2026-09-19 14:00 PT`
''',
        commentBodies: <String>[
          '''
### 🐧🛠️🐳 Bluefin-DX → ☁️🐧⚡ Enterprise Rodete
> **State**: `ACKED` | **Time**: `2026-09-19 14:56 PT`
''',
        ],
        lastCommentCreatedAt: '2026-09-19T21:56:45Z',
      );

      // 3. Open issue #11 where peer posted State: DONE (ready for us to verify
      // & close).
      const peerSettlingDone = RelayIssueRaw(
        number: 11,
        title: 'Peer DONE thread',
        state: 'OPEN',
        updatedAt: '2026-09-26T04:00:00Z',
        createdAt: '2026-09-26T03:00:00Z',
        url: 'https://github.com/kevmoo/agent-relay/issues/11',
        body: '''
### 🐧🛠️🐳 Bluefin-DX → ☁️🐧⚡ Enterprise Rodete
> **State**: `DONE` | **Time**: `2026-09-25 21:00 PT`
''',
        commentBodies: <String>[],
      );

      // 4. Open issue #12 where WE posted State: DONE and it was already
      // recorded at the previous sync watermark with 0 new comments.
      const ownSettledDone = RelayIssueRaw(
        number: 12,
        title: 'Our settled DONE thread',
        state: 'OPEN',
        updatedAt: '2026-09-26T03:50:00Z',
        createdAt: '2026-09-26T03:00:00Z',
        url: 'https://github.com/kevmoo/agent-relay/issues/12',
        body: '''
### ☁️🐧⚡ Enterprise Rodete → 🐧🛠️🐳 Bluefin-DX
> **State**: `DONE` | **Time**: `2026-09-25 20:50 PT`
''',
        commentBodies: <String>[],
      );

      final ossEnriched =
          [
                closedWithPostCloseReply,
                historicalClosedAcked,
                peerSettlingDone,
                ownSettledDone,
              ]
              .map(
                (r) => EnrichedRelayIssue.fromRaw(
                  r,
                  channel: 'oss',
                  repo: 'kevmoo/agent-relay',
                  selfPattern: selfPattern,
                ),
              )
              .toList();

      final prevState = <String, Object?>{
        'last_sync_utc': '2026-09-26T03:03:30Z',
        'last_sync_pt': '2026-09-25 20:03 PDT',
        'corp': {'git_head': '', 'issues': <String, Object?>{}},
        'oss': {
          'git_head': 'f76b591',
          'issues': <String, Object?>{
            '1': {
              'state': 'CLOSED',
              'comment_count': 1,
              'updatedAt': '2026-09-19T21:56:45Z',
              'last_state_tag': 'ACKED',
            },
            '10': {
              'state': 'CLOSED',
              'comment_count': 1,
              'updatedAt': '2026-09-26T03:03:29Z',
              'last_state_tag': 'DONE',
            },
            '12': {
              'state': 'OPEN',
              'comment_count': 0,
              'updatedAt': '2026-09-26T03:50:00Z',
              'last_state_tag': 'DONE',
            },
          },
        },
      };

      final built = buildRelayCheckReport(
        moniker: '☁️🐧⚡ Enterprise Rodete',
        lastSyncPt: '2026-09-25 20:03 PDT',
        nowUtc: '2026-09-26T04:05:00Z',
        nowPt: '2026-09-25 21:05 PDT',
        corpRepo: 'corp',
        ossRepo: 'kevmoo/agent-relay',
        corpOk: 'true',
        corpErr: '',
        ossOk: 'true',
        ossErr: '',
        newCorpSha: '',
        newOssSha: 'f76b591',
        prevState: prevState,
        corpEnriched: const <EnrichedRelayIssue>[],
        ossEnriched: ossEnriched,
      );

      expect(
        built.report,
        contains(
          '💬 +1 NEW COMMENT(S) [🌐 kevmoo/agent-relay] #10 '
          '[CLOSED ⚠️ POST-CLOSE]',
        ),
      );
      expect(
        built.report,
        contains(
          '🔴 [🌐 kevmoo/agent-relay] #10 ⚠️ [CLOSED — Post-Close Reply]',
        ),
      );
      expect(
        built.report,
        isNot(contains('#1 ⚠️ [CLOSED — Post-Close Reply]')),
      );
      expect(
        built.report,
        contains(
          '🔴 [🌐 kevmoo/agent-relay] #11 🟢 [SETTLING — Verify DONE & Close]',
        ),
      );
      expect(
        built.report,
        contains(
          '⏳ [🌐 kevmoo/agent-relay] #12 ✅ [SETTLED DONE — Ready to Close]',
        ),
      );
    });
  });
}
