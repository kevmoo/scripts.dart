/// Pure models, Markdown envelope parser, and delta/report builder for
/// `kscripts relay-whoami`.
library;

final _headerSplitArrow = RegExp('→|->');
final _fromLinePattern = RegExp(r'\*\*From:?\*\*:?\s*([^\n]+)');
final _toLinePattern = RegExp(r'\*\*To:?\*\*:?\s*([^\n]+)');
final _statePattern = RegExp(r'\*\*State\*\*:\s*`?([A-Z_]+)`?');
final _timePattern = RegExp(
  r'\*\*Time\*\*:\s*`?([0-9]{4}-[0-9]{2}-[0-9]{2}[^`|\n]+)`?',
);
final _todoLinePattern = RegExp(r'^\s*[-*]?\s*\[ \]\s+(.*)$');

/// Parsed metadata from a relay issue body or comment envelope.
final class RelayEnvelope {
  final String from;
  final String to;
  final String stateTag;
  final String timePt;
  final List<String> todos;

  const new({
    required this.from,
    required this.to,
    required this.stateTag,
    required this.timePt,
    required this.todos,
  });
}

/// Parses a Markdown relay envelope from [text], falling back gracefully when
/// `### <from> → <to>`, `**State**:`, or `**Time**:` headers are omitted.
RelayEnvelope parseRelayEnvelope(String? text, String fallbackTitle) {
  final raw = text ?? '';
  final lines = raw.split('\n');

  String? headerLine;
  for (final line in lines) {
    if (line.startsWith('### ') &&
        (line.contains('→') || line.contains('->'))) {
      headerLine = line;
      break;
    }
  }

  String from;
  String to;
  if (headerLine != null) {
    final stripped = headerLine.replaceFirst(RegExp(r'^###\s+'), '');
    final parts = stripped.split(_headerSplitArrow);
    from = parts.isNotEmpty ? parts[0].trim() : '';
    to = parts.length > 1 ? parts[1].trim() : '';
  } else {
    final fromMatch = _fromLinePattern.firstMatch(raw);
    final toMatch = _toLinePattern.firstMatch(raw);
    from = fromMatch?.group(1)?.trim() ?? 'unknown';
    to = toMatch?.group(1)?.trim() ?? fallbackTitle;
  }

  final stateMatch = _statePattern.firstMatch(raw);
  final stateTag = stateMatch?.group(1)?.trim() ?? 'OPEN';

  final timeMatch = _timePattern.firstMatch(raw);
  final timePt = timeMatch?.group(1)?.trim() ?? '';

  final todos = <String>[];
  for (final line in lines) {
    final match = _todoLinePattern.firstMatch(line);
    if (match != null) {
      todos.add(match.group(1)!.trim());
    }
  }

  return RelayEnvelope(
    from: from,
    to: to,
    stateTag: stateTag,
    timePt: timePt,
    todos: todos,
  );
}

/// Raw issue record decoded from `gh issue list` or `ggh issue list`.
final class RelayIssueRaw {
  final int number;
  final String title;
  final String state;
  final String updatedAt;
  final String createdAt;
  final String closedAt;
  final String url;
  final String body;
  final List<String> commentBodies;
  final String lastCommentCreatedAt;

  const new({
    required this.number,
    required this.title,
    required this.state,
    required this.updatedAt,
    required this.createdAt,
    required this.url,
    required this.body,
    required this.commentBodies,
    this.closedAt = '',
    this.lastCommentCreatedAt = '',
  });

  factory fromJson(Map<String, Object?> json) {
    final rawComments = json['comments'];
    final comments = <String>[];
    var lastCommentCreatedAt = '';
    if (rawComments is List) {
      for (final c in rawComments) {
        if (c is Map) {
          comments.add((c['body'] ?? '').toString());
          final created = (c['createdAt'] ?? '').toString();
          if (created.isNotEmpty) {
            lastCommentCreatedAt = created;
          }
        }
      }
    }
    return RelayIssueRaw(
      number: (json['number'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      state: (json['state'] ?? 'OPEN').toString(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      closedAt: (json['closedAt'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      commentBodies: comments,
      lastCommentCreatedAt: lastCommentCreatedAt,
    );
  }
}

/// Enriched relay issue with directional routing flags.
final class EnrichedRelayIssue {
  final String channel;
  final String channelBadge;
  final int number;
  final String key;
  final String title;
  final String state;
  final String url;
  final String updatedAt;
  final String createdAt;
  final String closedAt;
  final String lastCommentCreatedAt;
  final int commentCount;
  final RelayEnvelope opener;
  final RelayEnvelope latest;
  final List<String> activeTodos;
  final bool latestFromMe;
  final bool openedByMe;
  final bool addressedToMe;
  final bool hasPostCloseComment;

  const new({
    required this.channel,
    required this.channelBadge,
    required this.number,
    required this.key,
    required this.title,
    required this.state,
    required this.url,
    required this.updatedAt,
    required this.createdAt,
    required this.commentCount,
    required this.opener,
    required this.latest,
    required this.activeTodos,
    required this.latestFromMe,
    required this.openedByMe,
    required this.addressedToMe,
    this.closedAt = '',
    this.lastCommentCreatedAt = '',
    this.hasPostCloseComment = false,
  });

  factory fromRaw(
    RelayIssueRaw raw, {
    required String channel,
    required String repo,
    required RegExp selfPattern,
  }) {
    final opener = parseRelayEnvelope(raw.body, raw.title);
    final commentEnvelopes = [
      for (final b in raw.commentBodies) parseRelayEnvelope(b, raw.title),
    ];
    final latest = commentEnvelopes.isNotEmpty ? commentEnvelopes.last : opener;
    final activeTodos = latest.todos.isNotEmpty
        ? latest.todos
        : (raw.state == 'OPEN' && latest.stateTag != 'DONE'
              ? opener.todos
              : const <String>[]);
    final latestFromMe = selfPattern.hasMatch(latest.from);
    final openedByMe = selfPattern.hasMatch(opener.from);
    var unansweredToMe = selfPattern.hasMatch(raw.title);
    for (final turn in [opener, ...commentEnvelopes]) {
      if (selfPattern.hasMatch(turn.from)) {
        unansweredToMe = false;
      } else if (selfPattern.hasMatch(turn.to)) {
        unansweredToMe = true;
      }
    }
    final addressedToMe = unansweredToMe || selfPattern.hasMatch(latest.to);
    final hasPostCloseComment =
        raw.state == 'CLOSED' &&
        raw.closedAt.isNotEmpty &&
        raw.lastCommentCreatedAt.isNotEmpty &&
        raw.lastCommentCreatedAt.compareTo(raw.closedAt) > 0;

    return EnrichedRelayIssue(
      channel: channel,
      channelBadge: channel == 'corp' ? '🔒 $repo' : '🌐 $repo',
      number: raw.number,
      key: raw.number.toString(),
      title: raw.title,
      state: raw.state,
      url: raw.url,
      updatedAt: raw.updatedAt,
      createdAt: raw.createdAt,
      closedAt: raw.closedAt,
      lastCommentCreatedAt: raw.lastCommentCreatedAt,
      commentCount: raw.commentBodies.length,
      opener: opener,
      latest: latest,
      activeTodos: activeTodos,
      latestFromMe: latestFromMe,
      openedByMe: openedByMe,
      addressedToMe: addressedToMe,
      hasPostCloseComment: hasPostCloseComment,
    );
  }

  /// Whether a `CLOSED` issue has a post-close reply addressed to us that
  /// requires attention (either an active state tag, open checklist items, or a
  /// new comment since the last sync watermark).
  bool hasActionablePostCloseReply(Map<String, Object?> prevIssuesMap) {
    if (state != 'CLOSED' ||
        !hasPostCloseComment ||
        latestFromMe ||
        !addressedToMe) {
      return false;
    }
    final tag = latest.stateTag;
    if (tag == 'HANDOFF' || tag == 'BLOCKED' || tag == 'OPEN') {
      return true;
    }
    if (latest.todos.isNotEmpty) {
      return true;
    }
    final prev = _asStringObjectMap(prevIssuesMap[key]);
    final prevComments = (prev['comment_count'] as num?)?.toInt() ?? 0;
    return prev.isEmpty || commentCount > prevComments;
  }

  /// Whether this `OPEN` issue has our own `State: DONE` turn that was already
  /// recorded at the previous sync watermark with zero new comments since then
  /// (meaning it has settled across a turn and can now be closed).
  bool isSettledOwnDone(Map<String, Object?> prevIssuesMap) {
    if (state != 'OPEN' || !latestFromMe || latest.stateTag != 'DONE') {
      return false;
    }
    final prev = _asStringObjectMap(prevIssuesMap[key]);
    if (prev.isEmpty) return false;
    final prevState = (prev['state'] ?? '').toString();
    final prevComments = (prev['comment_count'] as num?)?.toInt() ?? -1;
    final prevTag = (prev['last_state_tag'] ?? '').toString();
    return prevState == 'OPEN' &&
        prevComments == commentCount &&
        prevTag == 'DONE';
  }

  Map<String, Object?> toStateSummary() => {
    'state': state,
    'updatedAt': updatedAt,
    'comment_count': commentCount,
    'last_from': latest.from,
    'last_to': latest.to,
    'last_state_tag': latest.stateTag,
  };
}

/// Computes human-readable delta lines comparing [current] issues against
/// [previousMap] from `sync_state.json`.
List<String> computeIssueDeltas(
  List<EnrichedRelayIssue> current,
  Map<String, Object?> previousMap,
) {
  final deltas = <String>[];
  for (final c in current) {
    final prevObj = previousMap[c.key];
    final prev = prevObj is Map<String, Object?> ? prevObj : null;
    final timeSuffix = c.latest.timePt.isNotEmpty
        ? ' | ${c.latest.timePt}'
        : '';

    if (prev == null) {
      deltas.add(
        '  🆕 NEW ISSUE [${c.channelBadge}] #${c.number} [${c.state}]: '
        '${c.title}\n'
        '     ↳ From: ${c.latest.from} → ${c.latest.to} | '
        'State: ${c.latest.stateTag}$timeSuffix',
      );
      continue;
    }

    final prevState = (prev['state'] ?? '').toString();
    final prevComments = (prev['comment_count'] as num?)?.toInt() ?? 0;
    final prevUpdated = (prev['updatedAt'] ?? '').toString();

    if (prevState != c.state) {
      deltas.add(
        '  🔄 STATE CHANGED [${c.channelBadge}] #${c.number} '
        '($prevState → ${c.state}): ${c.title}\n'
        '     ↳ Latest: ${c.latest.from} | '
        'State: ${c.latest.stateTag}$timeSuffix',
      );
    } else if (c.commentCount > prevComments) {
      final diff = c.commentCount - prevComments;
      final postCloseNote = c.hasPostCloseComment ? ' ⚠️ POST-CLOSE' : '';
      deltas.add(
        '  💬 +$diff NEW COMMENT(S) [${c.channelBadge}] #${c.number} '
        '[${c.state}$postCloseNote]: ${c.title}\n'
        '     ↳ Latest: ${c.latest.from} → ${c.latest.to} | '
        'State: ${c.latest.stateTag}$timeSuffix',
      );
    } else if (prevUpdated != c.updatedAt) {
      deltas.add(
        '  ✏️  UPDATED [${c.channelBadge}] #${c.number} [${c.state}]: '
        '${c.title} (updated ${c.updatedAt})',
      );
    }
  }
  return deltas;
}

/// Merges [current] issue summaries into a copy of [previousMap].
Map<String, Object?> mergeIssueStateMap(
  Map<String, Object?> previousMap,
  List<EnrichedRelayIssue> current,
) {
  final merged = Map<String, Object?>.of(previousMap);
  for (final issue in current) {
    merged[issue.key] = issue.toStateSummary();
  }
  return merged;
}

/// Formats the directional `--check` status report and updated `sync_state`
/// map.
({String report, Map<String, Object?> newState}) buildRelayCheckReport({
  required String moniker,
  required String lastSyncPt,
  required String nowUtc,
  required String nowPt,
  required String corpRepo,
  required String ossRepo,
  required String corpOk,
  required String corpErr,
  required String ossOk,
  required String ossErr,
  required String newCorpSha,
  required String newOssSha,
  required Map<String, Object?> prevState,
  required List<EnrichedRelayIssue> corpEnriched,
  required List<EnrichedRelayIssue> ossEnriched,
}) {
  final prevCorp = _asStringObjectMap(prevState['corp']);
  final prevOss = _asStringObjectMap(prevState['oss']);
  final prevCorpIssues = _asStringObjectMap(prevCorp['issues']);
  final prevOssIssues = _asStringObjectMap(prevOss['issues']);

  final deltas = <String>[
    if (corpOk == 'false')
      '  ⚠️  [🔒 $corpRepo] Issue query FAILED ($corpErr) — watermark preserved'
    else
      ...computeIssueDeltas(corpEnriched, prevCorpIssues),
    if (ossOk == 'false')
      '  ⚠️  [🌐 $ossRepo] Issue query FAILED ($ossErr) — watermark preserved'
    else
      ...computeIssueDeltas(ossEnriched, prevOssIssues),
  ];

  final allOpen = <EnrichedRelayIssue>[
    ...corpEnriched.where((i) => i.state == 'OPEN'),
    ...ossEnriched.where((i) => i.state == 'OPEN'),
  ];
  final postCloseActionable = <EnrichedRelayIssue>[
    ...corpEnriched.where((i) => i.hasActionablePostCloseReply(prevCorpIssues)),
    ...ossEnriched.where((i) => i.hasActionablePostCloseReply(prevOssIssues)),
  ];
  final settledOwnDoneKeys = <String>{
    for (final i in corpEnriched)
      if (i.isSettledOwnDone(prevCorpIssues)) 'corp:${i.key}',
    for (final i in ossEnriched)
      if (i.isSettledOwnDone(prevOssIssues)) 'oss:${i.key}',
  };

  final anyQueryFailed = corpOk == 'false' || ossOk == 'false';
  final report = _formatRelayCheckSections(
    moniker: moniker,
    lastSyncPt: lastSyncPt,
    corpRepo: corpRepo,
    ossRepo: ossRepo,
    corpFailed: corpOk == 'false',
    ossFailed: ossOk == 'false',
    anyQueryFailed: anyQueryFailed,
    deltas: deltas,
    allOpen: allOpen,
    postCloseActionable: postCloseActionable,
    settledOwnDoneKeys: settledOwnDoneKeys,
  );

  final newState = _buildUpdatedRelayState(
    prevState: prevState,
    prevCorp: prevCorp,
    prevOss: prevOss,
    prevCorpIssues: prevCorpIssues,
    prevOssIssues: prevOssIssues,
    anyQueryFailed: anyQueryFailed,
    nowUtc: nowUtc,
    nowPt: nowPt,
    newCorpSha: newCorpSha,
    newOssSha: newOssSha,
    corpOk: corpOk == 'true',
    ossOk: ossOk == 'true',
    corpEnriched: corpEnriched,
    ossEnriched: ossEnriched,
  );

  return (report: report, newState: newState);
}

Map<String, Object?> _asStringObjectMap(Object? value) =>
    (value as Map?)?.cast<String, Object?>() ?? const {};

String _formatRelayCheckSections({
  required String moniker,
  required String lastSyncPt,
  required String corpRepo,
  required String ossRepo,
  required bool corpFailed,
  required bool ossFailed,
  required bool anyQueryFailed,
  required List<String> deltas,
  required List<EnrichedRelayIssue> allOpen,
  required List<EnrichedRelayIssue> postCloseActionable,
  required Set<String> settledOwnDoneKeys,
}) {
  final inboundOnUs = <EnrichedRelayIssue>[
    ...allOpen.where((i) => !i.latestFromMe && i.addressedToMe),
    ...postCloseActionable,
  ];
  final waitingOnOthers = allOpen
      .where((i) => i.latestFromMe || (i.openedByMe && !i.addressedToMe))
      .toList();
  final fyiOther = allOpen
      .where((i) => !i.latestFromMe && !i.addressedToMe && !i.openedByMe)
      .toList();

  final buf = StringBuffer()
    ..writeln(
      '=== 📬 2. Issue & Comment Activity Since Last Sync ($lastSyncPt) ===',
    )
    ..writeln(
      deltas.isEmpty
          ? '  ✅ 0 issue or comment changes across Corp & GitHub relays '
                'since last sync.'
          : deltas.join('\n'),
    )
    ..writeln()
    ..writeln(
      '=== 📥 3. Action Required — Waiting on Us ($moniker) '
      '[${inboundOnUs.length}] ===',
    );
  if (corpFailed) {
    buf.writeln(
      '  ⚠️  [🔒 $corpRepo] Query failed; '
      'open corp issues could not be checked.',
    );
  }
  if (ossFailed) {
    buf.writeln(
      '  ⚠️  [🌐 $ossRepo] Query failed; '
      'open GitHub issues could not be checked.',
    );
  }
  buf
    ..writeln(
      inboundOnUs.isNotEmpty
          ? inboundOnUs.map(_formatInboundIssue).join('\n\n')
          : anyQueryFailed
          ? '  ⚪ 0 verified inbound threads on reachable channels.'
          : '  ✅ Nothing waiting on $moniker right now.',
    )
    ..writeln()
    ..writeln(
      '=== ⏳ 4. Outbound — Waiting on Other Agents '
      '[${waitingOnOthers.length}] ===',
    )
    ..writeln(
      waitingOnOthers.isNotEmpty
          ? waitingOnOthers
                .map(
                  (i) => _formatOutboundIssue(
                    i,
                    isSettledDone: settledOwnDoneKeys.contains(
                      '${i.channel}:${i.key}',
                    ),
                  ),
                )
                .join('\n\n')
          : anyQueryFailed
          ? '  ⚪ 0 verified outbound threads on reachable channels.'
          : '  ✅ Not waiting on any other agents '
                '(all outbound relays ACKED/closed).',
    );

  if (fyiOther.isNotEmpty) {
    buf
      ..writeln()
      ..writeln(
        '=== 👀 5. FYI — Open Threads Between Other Peers '
        '[${fyiOther.length}] ===',
      )
      ..writeln(
        fyiOther
            .map(
              (i) =>
                  '  ⚪ [${i.channelBadge}] #${i.number}: ${i.title} '
                  '(${i.latest.from} → ${i.latest.to})',
            )
            .join('\n'),
      );
  }
  return buf.toString().trimRight();
}

Map<String, Object?> _buildUpdatedRelayState({
  required Map<String, Object?> prevState,
  required Map<String, Object?> prevCorp,
  required Map<String, Object?> prevOss,
  required Map<String, Object?> prevCorpIssues,
  required Map<String, Object?> prevOssIssues,
  required bool anyQueryFailed,
  required String nowUtc,
  required String nowPt,
  required String newCorpSha,
  required String newOssSha,
  required bool corpOk,
  required bool ossOk,
  required List<EnrichedRelayIssue> corpEnriched,
  required List<EnrichedRelayIssue> ossEnriched,
}) {
  final prevLastSyncUtc = (prevState['last_sync_utc'] ?? nowUtc).toString();
  final prevLastSyncPt = (prevState['last_sync_pt'] ?? nowPt).toString();
  return <String, Object?>{
    'last_sync_utc': anyQueryFailed ? prevLastSyncUtc : nowUtc,
    'last_sync_pt': anyQueryFailed ? prevLastSyncPt : nowPt,
    'corp': {
      'git_head': newCorpSha.isNotEmpty
          ? newCorpSha
          : (prevCorp['git_head'] ?? '').toString(),
      'issues': corpOk
          ? mergeIssueStateMap(prevCorpIssues, corpEnriched)
          : prevCorpIssues,
    },
    'oss': {
      'git_head': newOssSha.isNotEmpty
          ? newOssSha
          : (prevOss['git_head'] ?? '').toString(),
      'issues': ossOk
          ? mergeIssueStateMap(prevOssIssues, ossEnriched)
          : prevOssIssues,
    },
  };
}

String _formatInboundIssue(EnrichedRelayIssue i) {
  final urlLine = i.url.isNotEmpty ? '\n     🔗 ${i.url}' : '';
  final sentSegment = i.latest.timePt.isNotEmpty
      ? ' | Sent: ${i.latest.timePt}'
      : '';
  final todoSection = i.activeTodos.isNotEmpty
      ? '\n     📋 Open Checklist Items (${i.activeTodos.length}):\n'
            '${i.activeTodos.map((t) => '        • [ ] $t').join('\n')}'
      : '';
  final statusBadge = i.state == 'CLOSED'
      ? ' ⚠️ [CLOSED — Post-Close Reply]'
      : i.latest.stateTag == 'DONE'
      ? ' 🟢 [SETTLING — Verify DONE & Close]'
      : '';
  return '  🔴 [${i.channelBadge}] #${i.number}$statusBadge: ${i.title}'
      '$urlLine\n'
      '     📨 Latest Turn: ${i.latest.from} → ${i.latest.to} | '
      'State: ${i.latest.stateTag}$sentSegment | '
      'Comments: ${i.commentCount}$todoSection';
}

String _formatOutboundIssue(
  EnrichedRelayIssue i, {
  bool isSettledDone = false,
}) {
  final urlLine = i.url.isNotEmpty ? '\n     🔗 ${i.url}' : '';
  final sentSegment = i.latest.timePt.isNotEmpty
      ? ' | Sent: ${i.latest.timePt}'
      : ' | Updated: ${i.updatedAt}';
  final todoSection = i.activeTodos.isNotEmpty
      ? '\n     📋 Pending Items Requested from Recipient '
            '(${i.activeTodos.length}):\n'
            '${i.activeTodos.map((t) => '        • [ ] $t').join('\n')}'
      : '';
  final statusBadge = isSettledDone
      ? ' ✅ [SETTLED DONE — Ready to Close]'
      : i.latest.stateTag == 'DONE'
      ? ' ⏳ [SETTLING DONE — Leave Open This Turn]'
      : '';
  return '  ⏳ [${i.channelBadge}] #${i.number}$statusBadge: ${i.title}'
      '$urlLine\n'
      '     🎯 Waiting On: ${i.latest.to} | '
      'Last State: ${i.latest.stateTag}$sentSegment | '
      'Comments: ${i.commentCount}$todoSection';
}
