import '../shared/gh_args.dart';

/// Exception thrown by `gh-view` operations.
class GhViewException extends CliException {
  const new(super.message, {super.exitCode = 1});
}

/// GitHub GraphQL `PullRequestReviewDecision` values.
extension type const ReviewDecision(String value) implements String {
  static const approved = ReviewDecision('APPROVED');
  static const changesRequested = ReviewDecision('CHANGES_REQUESTED');
  static const reviewRequired = ReviewDecision('REVIEW_REQUIRED');
  static const none = ReviewDecision('NONE');
}

/// GitHub StatusCheckRollup / CI rollup state values (plus synthetic `TREE_BROKEN`).
extension type const CiStatus(String value) implements String {
  static const success = CiStatus('SUCCESS');
  static const failure = CiStatus('FAILURE');
  static const error = CiStatus('ERROR');
  static const timedOut = CiStatus('TIMED_OUT');
  static const cancelled = CiStatus('CANCELLED');
  static const startupFailure = CiStatus('STARTUP_FAILURE');
  static const pending = CiStatus('PENDING');
  static const treeBroken = CiStatus('TREE_BROKEN');
  static const actionRequired = CiStatus('ACTION_REQUIRED');
  static const none = CiStatus('NONE');

  bool get isPassing => this == success || this == treeBroken;

  bool get isFailureConclusion =>
      this == failure ||
      this == error ||
      this == timedOut ||
      this == cancelled ||
      this == startupFailure;
}

CiStatus extractCiStatus(String repository, Map<String, dynamic>? commits) {
  final commitNodes = commits?['nodes'] as List<dynamic>?;
  if (commitNodes == null || commitNodes.isEmpty) return CiStatus.none;

  final firstCommit = commitNodes.first as Map<String, dynamic>?;
  final commitObj = firstCommit?['commit'] as Map<String, dynamic>?;
  final statusRollup = commitObj?['statusCheckRollup'] as Map<String, dynamic>?;
  final rawState = statusRollup?['state'] as String? ?? CiStatus.none;

  if (rawState == CiStatus.failure) {
    if (repository.toLowerCase() == 'flutter/flutter' &&
        _isFlutterTreeStatusOnlyFailure(statusRollup)) {
      return CiStatus.treeBroken;
    }
    if (_isActionRequiredOnlyFailure(statusRollup, repository: repository)) {
      return CiStatus.actionRequired;
    }
  }

  return CiStatus(rawState);
}

bool _isActionRequiredOnlyFailure(
  Map<String, dynamic>? statusRollup, {
  String repository = '',
}) {
  final contextNodes = _extractRollupContextNodes(statusRollup);
  final isFlutter = repository.toLowerCase() == 'flutter/flutter';

  var hasActionRequired = false;
  var hasRealFailure = false;

  for (final ctx in contextNodes) {
    if (isFlutter && ctx['context'] == 'tree-status') continue;
    final raw = (ctx['state'] ?? ctx['conclusion']) as String? ?? '';
    final status = CiStatus(raw);
    if (status == CiStatus.actionRequired) {
      if (_isActionRequiredCheckRealFailure(ctx)) {
        hasRealFailure = true;
      } else {
        hasActionRequired = true;
      }
    } else if (status.isFailureConclusion) {
      hasRealFailure = true;
    }
  }

  return hasActionRequired && !hasRealFailure;
}

final _failureKeywordRegex = RegExp(
  r'(?<!\b(?:0|no|none|zero)\s)\b(?:failed|failure)(?!\s*:\s*0\b)\b',
  caseSensitive: false,
);
final _bulletItemRegex = RegExp(r'^\s*[-*]\s+(.+)$', multiLine: true);
final _markdownNoiseRegex = RegExp(r'\*\*|\[([^\]]+)\]\([^)]+\)');
final _leadingHeadingRegex = RegExp(r'^#+\s*');

bool _isActionRequiredCheckRealFailure(Map<String, dynamic> ctx) {
  final text = ctx['text'] as String? ?? '';
  final summary = ctx['summary'] as String? ?? '';
  final title = ctx['title'] as String? ?? '';
  return _failureKeywordRegex.hasMatch(text) ||
      _failureKeywordRegex.hasMatch(summary) ||
      _failureKeywordRegex.hasMatch(title);
}

List<Map<String, dynamic>> _extractRollupContextNodes(
  Map<String, dynamic>? statusRollup,
) {
  final contexts = statusRollup?['contexts'] as Map<String, dynamic>?;
  final nodes = contexts?['nodes'] as List<dynamic>? ?? const [];
  return nodes.whereType<Map<String, dynamic>>().toList();
}

/// Extracts a concise, table-safe summary of failing or action-required
/// CI check runs from the latest commit's `statusCheckRollup`.
String? extractCiDetail(Map<String, dynamic>? commits) {
  final commitNodes = commits?['nodes'] as List<dynamic>?;
  if (commitNodes == null || commitNodes.isEmpty) return null;
  final firstCommit = commitNodes.first as Map<String, dynamic>?;
  final commitObj = firstCommit?['commit'] as Map<String, dynamic>?;
  final statusRollup = commitObj?['statusCheckRollup'] as Map<String, dynamic>?;
  final contextNodes = _extractRollupContextNodes(statusRollup);

  final failingNodes = contextNodes.where(_isFailingOrActionContext).toList();
  if (failingNodes.isEmpty) return null;

  final filtered = failingNodes.length > 1
      ? failingNodes.where((c) => c['context'] != 'tree-status').toList()
      : failingNodes;
  final nonTreeNodes = filtered.isNotEmpty ? filtered : failingNodes;
  final realFailures = nonTreeNodes.where(_isRealFailureContext).toList();
  final targets = realFailures.isNotEmpty ? realFailures : nonTreeNodes;

  final details = targets
      .map(_formatCheckContextDetail)
      .where((s) => s.isNotEmpty)
      .toList();
  if (details.isEmpty) return null;
  if (details.length <= 2) return details.join(', ');
  return '${details.take(2).join(', ')} +${details.length - 2} more';
}

bool _isFailingOrActionContext(Map<String, dynamic> ctx) {
  final raw = (ctx['state'] ?? ctx['conclusion']) as String? ?? '';
  final status = CiStatus(raw);
  return status == CiStatus.actionRequired || status.isFailureConclusion;
}

bool _isRealFailureContext(Map<String, dynamic> ctx) {
  final raw = (ctx['state'] ?? ctx['conclusion']) as String? ?? '';
  final status = CiStatus(raw);
  if (status == CiStatus.actionRequired) {
    return _isActionRequiredCheckRealFailure(ctx);
  }
  return status == CiStatus.failure ||
      status == CiStatus.error ||
      status == CiStatus.timedOut ||
      status == CiStatus.startupFailure;
}

String _formatCheckContextDetail(Map<String, dynamic> ctx) {
  final rawName = (ctx['name'] ?? ctx['context']) as String? ?? '';
  final name = _sanitizeCheckText(rawName);
  final snippet = _extractCheckSnippet(ctx, name);
  if (name.isEmpty) return snippet ?? '';
  if (snippet == null || snippet.isEmpty) return name;
  return '$name: $snippet';
}

String _sanitizeCheckText(String input) => input
    .replaceAll('\r', '')
    .replaceAll('\n', ' ')
    .replaceAllMapped(_markdownNoiseRegex, (m) => m.group(1) ?? '')
    .replaceAll('`', '')
    .replaceFirst(_leadingHeadingRegex, '')
    .replaceAll('|', '/')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String? _extractCheckSnippet(Map<String, dynamic> ctx, String checkName) {
  final text = (ctx['text'] as String? ?? '').replaceAll('\r', '').trim();
  final bullets = _bulletItemRegex
      .allMatches(text)
      .map((m) => _sanitizeCheckText(m.group(1)!))
      .where((s) => s.isNotEmpty)
      .toList();
  if (bullets.isNotEmpty) {
    final shown = bullets.take(2).join(', ');
    return bullets.length > 2 ? '$shown +${bullets.length - 2} more' : shown;
  }

  for (final raw in [text, ctx['summary'], ctx['description'], ctx['title']]) {
    final line = _firstCleanNonTableLine(raw as String? ?? '', checkName);
    if (line != null) return line;
  }
  return null;
}

String? _firstCleanNonTableLine(String raw, String checkName) {
  final str = raw.replaceAll('\r', '').trim();
  if (str.isEmpty) return null;
  for (final rawLine in str.split('\n')) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty || trimmed.startsWith('|')) continue;
    final cleaned = _sanitizeCheckText(trimmed);
    if (cleaned.isNotEmpty &&
        cleaned.length <= 60 &&
        cleaned.toLowerCase() != checkName.toLowerCase()) {
      return cleaned;
    }
    return null;
  }
  return null;
}

bool _isFlutterTreeStatusOnlyFailure(Map<String, dynamic>? statusRollup) {
  final contexts = statusRollup?['contexts'] as Map<String, dynamic>?;
  final contextNodes = contexts?['nodes'] as List<dynamic>? ?? [];

  var hasRealFailure = false;
  var hasTreeStatusFailure = false;

  for (final ctx in contextNodes.whereType<Map<String, dynamic>>()) {
    final status = _evaluateFlutterContext(ctx);
    if (status == _FlutterContextStatus.realFailure) {
      hasRealFailure = true;
    } else if (status == _FlutterContextStatus.treeStatusFailure) {
      hasTreeStatusFailure = true;
    }
  }

  return hasTreeStatusFailure && !hasRealFailure;
}

enum _FlutterContextStatus { ok, treeStatusFailure, realFailure }

_FlutterContextStatus _evaluateFlutterContext(Map<String, dynamic> ctx) =>
    switch (ctx['__typename']) {
      'StatusContext' => switch (ctx['state']) {
        CiStatus.failure || CiStatus.error =>
          ctx['context'] == 'tree-status'
              ? _FlutterContextStatus.treeStatusFailure
              : _FlutterContextStatus.realFailure,
        _ => _FlutterContextStatus.ok,
      },
      'CheckRun' => switch (ctx['conclusion']) {
        CiStatus.failure ||
        CiStatus.actionRequired ||
        CiStatus.timedOut ||
        CiStatus.cancelled ||
        CiStatus.startupFailure => _FlutterContextStatus.realFailure,
        _ => _FlutterContextStatus.ok,
      },
      _ => _FlutterContextStatus.ok,
    };
