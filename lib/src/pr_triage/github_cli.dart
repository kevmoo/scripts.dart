import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'pr_context.dart';

export 'pr_context.dart'
    show
        CommandRunner,
        PrCheckRun,
        PrComment,
        PrConflictAnalysis,
        PrContext,
        PrGraphData,
        PrReview,
        PrReviewThread,
        analyzePrConflicts,
        fetchPrChecks,
        fetchPrGraphQLData,
        ghExecutableForHost,
        parseMergeTreeConflictOutput,
        runCommand;

final _digitsOnly = RegExp(r'^\d+$');
final _scpRemotePattern = RegExp(r'^(?:[^@/\s]+@)?([^:/\s]+):(.+)$');

/// Parses a GitHub or GitHub Enterprise pull request URL into its components.
({String host, String owner, String repo, String prNumber})? parsePrUrl(
  String input,
) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'https://$trimmed',
  );
  if (uri == null || !uri.hasAuthority || !uri.host.contains('.')) {
    return null;
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments case [final owner, final repo, 'pull', final pr, ...]
      when _digitsOnly.hasMatch(pr)) {
    return (
      host: uri.host.toLowerCase(),
      owner: owner,
      repo: repo,
      prNumber: pr,
    );
  }
  return null;
}

/// Parses a Git remote URL (HTTPS, `ssh://`, or SCP-style `git@host:owner/repo`)
/// into `(host, owner, repo)`.
({String host, String owner, String repo})? parseGitRemoteUrl(
  String remoteUrl,
) {
  final trimmed = remoteUrl.trim();
  final scpMatch = trimmed.contains('://')
      ? null
      : _scpRemotePattern.firstMatch(trimmed);
  final normalized = scpMatch != null
      ? 'ssh://${scpMatch.group(1)}/${scpMatch.group(2)}'
      : trimmed;
  final uri = Uri.tryParse(normalized);
  if (uri == null || !uri.hasAuthority || !uri.host.contains('.')) {
    return null;
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments case [final owner, final rawRepo]) {
    final repo = rawRepo.replaceFirst(RegExp(r'\.git$'), '');
    if (repo.isNotEmpty) {
      return (host: uri.host.toLowerCase(), owner: owner, repo: repo);
    }
  }
  return null;
}

ArgParser buildPrContextArgParser() => ArgParser()
  ..addOption('pr', abbr: 'p', help: 'PR number or GitHub PR URL')
  ..addOption('dir', abbr: 'C', help: 'Path to target git repository directory')
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this usage information.',
  );

/// Parses CLI arguments and resolves the [PrContext] for git operations.
Future<PrContext> resolvePrContext(
  List<String> args, {
  required Never Function(String message) onFail,
  CommandRunner runCommand = runCommand,
}) async {
  final parser = buildPrContextArgParser();
  ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    onFail(e.message);
  }

  final targetDir = results.option('dir');
  final prInput =
      results.option('pr') ??
      (results.rest.isNotEmpty ? results.rest.first : null);

  return resolvePrContextFromArgs(
    prInput: prInput,
    targetDir: targetDir,
    onFail: onFail,
    runCommand: runCommand,
  );
}

/// Resolves [PrContext] from pre-parsed CLI inputs.
Future<PrContext> resolvePrContextFromArgs({
  String? prInput,
  String? targetDir,
  required Never Function(String message) onFail,
  bool requireLocalRepo = true,
  CommandRunner runCommand = runCommand,
  Map<String, String>? environment,
}) async {
  final workingDir = targetDir != null
      ? Directory(targetDir).absolute.path
      : Directory.current.absolute.path;
  if (!await Directory(workingDir).exists()) {
    onFail('Target directory "$workingDir" does not exist.');
  }

  final parsedInput = _parsePrInput(prInput, onFail);
  if (!requireLocalRepo &&
      targetDir == null &&
      parsedInput.owner != null &&
      parsedInput.repo != null &&
      parsedInput.prNumber != null) {
    return PrContext(
      workingDir: workingDir,
      prNumber: parsedInput.prNumber!,
      owner: parsedInput.owner!,
      repo: parsedInput.repo!,
      host: parsedInput.host,
    );
  }

  final remoteInfo = await _resolveGitRemoteInfo(workingDir, runCommand);
  final resolvedHost = parsedInput.host ?? remoteInfo.host;
  final ghExe = ghExecutableForHost(resolvedHost, environment: environment);

  final (ghOwner, ghRepo) = await _resolveLocalRepoOwner(
    workingDir,
    runCommand,
    ghExecutable: ghExe,
  );
  final localOwner = ghOwner ?? remoteInfo.owner;
  final localRepo = ghRepo ?? remoteInfo.repo;
  final resolvedOwner = parsedInput.owner ?? localOwner;
  final resolvedRepo = parsedInput.repo ?? localRepo;

  if (resolvedOwner == null || resolvedRepo == null) {
    onFail('Failed to resolve repository owner and name.');
  }

  if (localOwner != null &&
      localRepo != null &&
      parsedInput.owner != null &&
      parsedInput.repo != null &&
      localRepo.toLowerCase() != parsedInput.repo!.toLowerCase() &&
      !remoteInfo.slugs.contains(
        '${parsedInput.owner}/${parsedInput.repo}'.toLowerCase(),
      )) {
    onFail(
      'The target directory "$workingDir" is for repository '
      '"$localOwner/$localRepo", but the specified PR is for repository '
      '"${parsedInput.owner}/${parsedInput.repo}".',
    );
  }

  final tempContext = PrContext(
    workingDir: workingDir,
    prNumber: parsedInput.prNumber ?? '',
    owner: resolvedOwner,
    repo: resolvedRepo,
    host: resolvedHost,
  );
  final prNumber =
      parsedInput.prNumber ??
      await _detectPrNumberFromBranch(
        workingDir,
        onFail,
        runCommand,
        ghExecutable: ghExe,
        repoSlug: tempContext.repoSlug,
      );

  return PrContext(
    workingDir: workingDir,
    prNumber: prNumber,
    owner: resolvedOwner,
    repo: resolvedRepo,
    host: resolvedHost,
  );
}

({String? host, String? owner, String? repo, String? prNumber}) _parsePrInput(
  String? prInput,
  Never Function(String message) onFail,
) {
  if (prInput == null) {
    return (host: null, owner: null, repo: null, prNumber: null);
  }
  final parsedUrl = parsePrUrl(prInput);
  if (parsedUrl != null) {
    return (
      host: parsedUrl.host,
      owner: parsedUrl.owner,
      repo: parsedUrl.repo,
      prNumber: parsedUrl.prNumber,
    );
  }
  if (_digitsOnly.hasMatch(prInput)) {
    return (host: null, owner: null, repo: null, prNumber: prInput);
  }
  onFail('Invalid PR argument. Please provide a PR number or a GitHub PR URL.');
}

typedef _GitRemoteInfo = ({
  String? host,
  String? owner,
  String? repo,
  Set<String> slugs,
});

Future<_GitRemoteInfo> _resolveGitRemoteInfo(
  String workingDir,
  CommandRunner runCommand,
) async {
  String output;
  try {
    output = await runCommand('git', [
      'remote',
      '-v',
    ], workingDirectory: workingDir);
  } catch (_) {
    return (host: null, owner: null, repo: null, slugs: const <String>{});
  }

  final byName = <String, ({String host, String owner, String repo})>{};
  final slugs = <String>{};
  for (final line in output.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final parsed = parseGitRemoteUrl(parts[1]);
    if (parsed == null) continue;
    byName.putIfAbsent(parts[0], () => parsed);
    slugs.add('${parsed.owner}/${parsed.repo}'.toLowerCase());
  }
  final preferred =
      byName['origin'] ?? byName['upstream'] ?? byName.values.firstOrNull;
  return (
    host: preferred?.host,
    owner: preferred?.owner,
    repo: preferred?.repo,
    slugs: slugs,
  );
}

/// Extension getters for [PrCheckRun].
extension PrCheckRunExt on PrCheckRun {
  bool get isCancelled =>
      bucket == 'cancel' ||
      state.toUpperCase() == 'CANCELLED' ||
      state.toUpperCase() == 'TIMED_OUT';

  bool get isFail =>
      bucket == 'fail' ||
      isCancelled ||
      state.toUpperCase() == 'STARTUP_FAILURE' ||
      isActionRequired;

  bool get isPending => bucket == 'pending';
  bool get isActionRequired => state.toUpperCase() == 'ACTION_REQUIRED';
}

/// Extracts the workflow run ID from a GitHub Actions URL
/// (e.g. `.../actions/runs/12345`).
String? parseRunIdFromLink(String link) {
  final rawSegments = Uri.tryParse(link)?.pathSegments ?? const [];
  final segments = rawSegments.where((s) => s.isNotEmpty).toList();
  final idx = segments.indexOf('runs');
  if (idx > 0 && segments[idx - 1] == 'actions' && idx + 1 < segments.length) {
    final candidate = segments[idx + 1];
    if (_digitsOnly.hasMatch(candidate)) return candidate;
  }
  return null;
}

/// Extracts the check run ID from a GitHub check run or job URL.
String? parseCheckRunIdFromLink(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null) return null;

  final queryCheckRunId = uri.queryParameters['check_run_id'];
  if (queryCheckRunId != null && _digitsOnly.hasMatch(queryCheckRunId)) {
    return queryCheckRunId;
  }

  final rawSegments = uri.pathSegments;
  final segments = rawSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;

  final last = segments.last;
  if (!_digitsOnly.hasMatch(last)) return null;

  final length = segments.length;
  if (length >= 2 && segments[length - 2] == 'check-runs') {
    return last;
  }

  if (length >= 3 &&
      (segments[length - 2] == 'job' || segments[length - 2] == 'jobs') &&
      segments.contains('actions') &&
      segments.contains('runs')) {
    return last;
  }

  if (length >= 2 &&
      segments[length - 2] == 'runs' &&
      !segments.contains('actions')) {
    return last;
  }

  return null;
}

/// Fetches logs and annotations for a failed status check.
Future<String> fetchFailedCheckLog(
  PrContext context,
  PrCheckRun check, {
  CommandRunner runCommand = runCommand,
  String headSha = '',
}) async {
  final link = check.link;
  final runId = parseRunIdFromLink(link);
  var checkRunId = parseCheckRunIdFromLink(link);

  Future<String> ghRepoApi(String subpath) =>
      runCommand(context.ghExecutable(), [
        'api',
        ...context.apiHostArgs,
        '--allow-escape-sequences',
        'repos/${context.owner}/${context.repo}/$subpath',
      ], workingDirectory: context.workingDir);

  Map<dynamic, dynamic>? matchedCheckRun;
  if (runId == null && (checkRunId != null || headSha.isNotEmpty)) {
    matchedCheckRun = await _fetchExternalCheckRun(
      check,
      checkRunId: checkRunId,
      headSha: headSha,
      ghRepoApi: ghRepoApi,
    );
    checkRunId ??= matchedCheckRun?['id']?.toString();
  }

  final annotations = await _fetchCheckRunAnnotations(checkRunId, ghRepoApi);
  final logBody = runId != null
      ? await _fetchActionsRunLog(
          context,
          runId,
          ghRepoApi: ghRepoApi,
          runCommand: runCommand,
        )
      : _formatNonActionsCheckLog(check, matchedCheckRun);

  return annotations.isEmpty
      ? logBody
      : 'Check Annotations:\n${annotations.join("\n")}\n\n$logBody';
}

Future<Map<dynamic, dynamic>?> _fetchExternalCheckRun(
  PrCheckRun check, {
  required String? checkRunId,
  required String headSha,
  required Future<String> Function(String) ghRepoApi,
}) async {
  try {
    if (checkRunId != null) {
      final payload = await ghRepoApi('check-runs/$checkRunId');
      final decoded = jsonDecode(payload);
      if (decoded is Map) return decoded;
    }
    if (headSha.isNotEmpty) {
      final encodedName = Uri.encodeQueryComponent(check.name);
      final payload = await ghRepoApi(
        'commits/$headSha/check-runs?check_name=$encodedName&per_page=100',
      );
      final decoded = jsonDecode(payload) as Map<dynamic, dynamic>;
      final checkRuns = decoded['check_runs'] as List<dynamic>? ?? const [];
      final matching = checkRuns
          .whereType<Map<dynamic, dynamic>>()
          .where((c) => c['name'] == check.name)
          .toList();
      if (matching.isEmpty) return null;
      final targetState = check.state.toLowerCase();
      return matching.firstWhere(
        (c) => c['conclusion']?.toString().toLowerCase() == targetState,
        orElse: () => matching.last,
      );
    }
  } catch (_) {
    // Fall back gracefully if check-runs endpoint is unavailable.
  }
  return null;
}

String _formatNonActionsCheckLog(
  PrCheckRun check,
  Map<dynamic, dynamic>? matchedCheckRun,
) {
  final link = check.link;
  final conclusion = matchedCheckRun?['conclusion']?.toString().toLowerCase();
  final output = matchedCheckRun?['output'] as Map<dynamic, dynamic>?;
  final summary = output?['summary']?.toString().trim() ?? '';
  final text = output?['text']?.toString().trim() ?? '';
  final details = [
    if (summary.isNotEmpty) summary,
    if (text.isNotEmpty && text != summary) text,
  ].join('\n\n');

  final isActionRequired =
      conclusion == 'action_required' || check.isActionRequired;
  if (isActionRequired) {
    final msg = details.isNotEmpty
        ? details
        : 'Check run requires manual trigger or approval.';
    return 'ACTION_REQUIRED: $msg\nInspect details at: $link';
  }
  if (details.isNotEmpty) {
    return '$details\nInspect details at: $link';
  }
  return 'Non-GitHub Actions run. Inspect details at: $link';
}

Future<String> _fetchActionsRunLog(
  PrContext context,
  String runId, {
  required Future<String> Function(String) ghRepoApi,
  required CommandRunner runCommand,
}) async {
  final combinedLog = await _fetchCheckRunJobLogs(runId, ghRepoApi);
  if (combinedLog != null) return combinedLog;

  try {
    return await runCommand(context.ghExecutable(), [
      '-R',
      context.repoSlug,
      'run',
      'view',
      runId,
      '--log-failed',
    ], workingDirectory: context.workingDir);
  } catch (e) {
    return 'Failed to fetch logs: $e';
  }
}

/// Posts a reply to a PR review comment using its numeric [commentId].
Future<void> _replyToComment(
  PrContext context, {
  required String commentId,
  required String body,
  CommandRunner runCommand = runCommand,
  Map<String, String>? environment,
}) async {
  if (!_digitsOnly.hasMatch(commentId)) {
    throw ArgumentError('Comment ID must be a numeric database ID.');
  }
  if (body.trim().isEmpty) {
    throw ArgumentError('Comment body cannot be empty.');
  }

  final endpoint =
      'repos/${context.owner}/${context.repo}/pulls/${context.prNumber}'
      '/comments/$commentId/replies';
  await runCommand(context.ghExecutable(environment: environment), [
    'api',
    ...context.apiHostArgs,
    endpoint,
    '-f',
    'body=$body',
  ], workingDirectory: context.workingDir);
}

/// Resolves a review thread via GraphQL using its [threadId]
/// (e.g. `PRRT_...`).
Future<void> _resolveReviewThread(
  PrContext context, {
  required String threadId,
  CommandRunner runCommand = runCommand,
  Map<String, String>? environment,
}) async {
  if (threadId.trim().isEmpty) {
    throw ArgumentError('Thread ID cannot be empty.');
  }
  const mutation = r'''
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread {
        isResolved
      }
    }
  }
  ''';

  final response = await runCommand(
    context.ghExecutable(environment: environment),
    [
      'api',
      ...context.apiHostArgs,
      'graphql',
      '-f',
      'query=$mutation',
      '-f',
      'threadId=$threadId',
    ],
    workingDirectory: context.workingDir,
  );

  final parsed = jsonDecode(response) as Map<String, dynamic>;
  if (parsed['errors'] != null) {
    throw Exception('GraphQL errors resolving thread: ${parsed['errors']}');
  }
}

/// Replies to a comment (if [commentId] and [body] are provided) and resolves
/// the [threadId].
Future<void> replyAndResolveThread(
  PrContext context, {
  required String threadId,
  String? commentId,
  String? body,
  CommandRunner runCommand = runCommand,
  Map<String, String>? environment,
}) async {
  final hasCommentId = commentId != null && commentId.trim().isNotEmpty;
  final hasBody = body != null && body.trim().isNotEmpty;
  if (hasCommentId != hasBody) {
    throw ArgumentError(
      'Both commentId and body must be provided and non-empty, or both must '
      'be null/empty.',
    );
  }
  if (hasCommentId && hasBody) {
    await _replyToComment(
      context,
      commentId: commentId,
      body: body,
      runCommand: runCommand,
      environment: environment,
    );
  }
  await _resolveReviewThread(
    context,
    threadId: threadId,
    runCommand: runCommand,
    environment: environment,
  );
}

/// Normalizes a comma-separated list of reviewer logins by stripping leading
/// `@` prefixes and whitespace.
String normalizeReviewerLogins(String rawLogins) => rawLogins
    .split(',')
    .map((s) => s.trim().replaceFirst(RegExp('^@+'), '').trim())
    .where((s) => s.isNotEmpty)
    .toSet()
    .join(',');

/// Formats a normalized comma-separated list of reviewer logins as `@login`
/// mentions separated by `, `.
String formatReviewerMentions(String normalizedLogins) => normalizedLogins
    .split(',')
    .where((s) => s.isNotEmpty)
    .map((r) => '@$r')
    .join(', ');

/// Posts an optional top-level PR [comment], optionally dismisses a stale
/// review by its numeric [dismissReviewId] (with [dismissMessage]), and
/// re-requests review from [reviewerLogins] (`--add-reviewer`).
///
/// If dismissing the review fails (e.g. `403 Forbidden` on external
/// repositories), [onWarning] is invoked and the reviewer is still
/// re-requested so the PR is guaranteed to re-enter their review queue.
Future<void> reRequestPrReview(
  PrContext context, {
  required String reviewerLogins,
  String? comment,
  String? dismissReviewId,
  String? dismissMessage,
  void Function(String)? onWarning,
  CommandRunner runCommand = runCommand,
  Map<String, String>? environment,
}) async {
  final normalizedLogins = normalizeReviewerLogins(reviewerLogins);
  if (normalizedLogins.isEmpty) {
    throw ArgumentError('Reviewer login cannot be empty.');
  }
  final cleanDismissId = dismissReviewId?.trim() ?? '';
  if (cleanDismissId.isNotEmpty && !_digitsOnly.hasMatch(cleanDismissId)) {
    throw ArgumentError('Dismiss review ID must be a numeric database ID.');
  }
  if (comment != null && comment.trim().isEmpty) {
    throw ArgumentError('Comment body cannot be empty.');
  }
  final ghExe = context.ghExecutable(environment: environment);

  if (comment != null) {
    await runCommand(ghExe, [
      'pr',
      'comment',
      context.prNumber,
      '-R',
      context.repoSlug,
      '--body',
      comment,
    ], workingDirectory: context.workingDir);
  }

  if (cleanDismissId.isNotEmpty) {
    final mentions = formatReviewerMentions(normalizedLogins);
    final msg = (dismissMessage != null && dismissMessage.trim().isNotEmpty)
        ? dismissMessage.trim()
        : 'Addressed review feedback; re-requesting review from $mentions.';
    final endpoint =
        'repos/${context.owner}/${context.repo}/pulls/${context.prNumber}'
        '/reviews/$cleanDismissId/dismissals';
    try {
      await runCommand(ghExe, [
        'api',
        ...context.apiHostArgs,
        '-X',
        'PUT',
        endpoint,
        '-f',
        'message=$msg',
      ], workingDirectory: context.workingDir);
    } catch (e) {
      (onWarning ?? print)(
        'WARNING: Failed to dismiss review $cleanDismissId ($e); '
        'proceeding to re-request review.',
      );
    }
  }

  await runCommand(ghExe, [
    'pr',
    'edit',
    context.prNumber,
    '-R',
    context.repoSlug,
    '--add-reviewer',
    normalizedLogins,
  ], workingDirectory: context.workingDir);
}

Future<String> _detectPrNumberFromBranch(
  String workingDir,
  Never Function(String) onFail,
  CommandRunner runCommand, {
  required String ghExecutable,
  required String repoSlug,
}) async {
  String branch;
  try {
    branch = (await runCommand('git', [
      'symbolic-ref',
      '--short',
      'HEAD',
    ], workingDirectory: workingDir)).trim();
  } catch (_) {
    branch = '';
  }
  if (branch.isEmpty || branch == 'main' || branch == 'master') {
    onFail(
      'Active branch is ${branch.isEmpty ? 'detached HEAD' : '"$branch"'}. '
      'Please specify a target PR number or URL.',
    );
  }

  final listOutput = await runCommand(ghExecutable, [
    'pr',
    'list',
    '-R',
    repoSlug,
    '--head',
    branch,
    '--json',
    'number,url',
  ], workingDirectory: workingDir);
  final decodedList = jsonDecode(listOutput);
  final listJson = decodedList is List<dynamic>
      ? decodedList
      : const <dynamic>[];
  if (listJson.isEmpty) {
    onFail(
      'Error: Ambiguous context. No open PR found for branch "$branch". '
      'Do not guess. Please explicitly ask the user for a PR number or URL.',
    );
  }
  if (listJson.length > 1) {
    onFail(
      'Error: Ambiguous context. Multiple open PRs found for branch "$branch". '
      'Do not guess. Please explicitly ask the user which PR number or URL to '
      'target.',
    );
  }
  final firstPr = listJson[0];
  if (firstPr is! Map || firstPr['number'] == null) {
    onFail('Error: Unexpected PR data format from "gh pr list".');
  }
  return firstPr['number'].toString();
}

Future<(String?, String?)> _resolveLocalRepoOwner(
  String workingDir,
  CommandRunner runCommand, {
  required String ghExecutable,
}) async {
  try {
    final repoOutput = await runCommand(ghExecutable, [
      'repo',
      'view',
      '--json',
      'owner,name',
    ], workingDirectory: workingDir);
    final repoJson = jsonDecode(repoOutput) as Map<String, dynamic>;
    final localOwner =
        (repoJson['owner'] as Map<String, dynamic>)['login'] as String;
    final localRepo = repoJson['name'] as String;
    return (localOwner, localRepo);
  } catch (_) {
    return (null, null);
  }
}

Future<List<String>> _fetchCheckRunAnnotations(
  String? checkRunId,
  Future<String> Function(String) ghRepoApi,
) async {
  if (checkRunId == null) return const [];
  try {
    final annOutput = await ghRepoApi('check-runs/$checkRunId/annotations');
    final annList = jsonDecode(annOutput) as List<dynamic>;
    return annList
        .whereType<Map<dynamic, dynamic>>()
        .map(_formatCheckAnnotation)
        .nonNulls
        .toList();
  } catch (_) {
    return const [];
  }
}

String? _formatCheckAnnotation(Map<dynamic, dynamic> ann) {
  final message = ann['message']?.toString() ?? '';
  if (message.isEmpty) return null;

  final path = ann['path']?.toString() ?? '';
  final startLine = ann['start_line'];
  final level = ann['annotation_level']?.toString() ?? '';
  final title = ann['title']?.toString() ?? '';
  final pathPart = path.isNotEmpty ? '$path:$startLine ' : '';
  final titlePart = title.isNotEmpty ? '($title): ' : '';
  return 'Annotation [$level] $pathPart$titlePart$message';
}

Future<String?> _fetchCheckRunJobLogs(
  String runId,
  Future<String> Function(String) ghRepoApi,
) async {
  try {
    final jobsOutput = await ghRepoApi('actions/runs/$runId/jobs');
    final jobsJson = jsonDecode(jobsOutput) as Map<String, dynamic>;
    final jobsList = (jobsJson['jobs'] as List<dynamic>? ?? [])
        .whereType<Map<dynamic, dynamic>>();
    final failedJobs = jobsList.where(_isFailedJob).toList();
    if (failedJobs.isEmpty) return null;

    final logBuffers = <String>[];
    for (final job in failedJobs) {
      final formatted = await _fetchSingleJobLog(job, ghRepoApi);
      if (formatted != null) logBuffers.add(formatted);
    }
    return logBuffers.isNotEmpty ? logBuffers.join('\n\n') : null;
  } catch (_) {
    return null;
  }
}

bool _isFailedJob(Map<dynamic, dynamic> job) {
  final conc = job['conclusion']?.toString();
  return conc == 'failure' ||
      conc == 'timed_out' ||
      conc == 'cancelled' ||
      conc == 'startup_failure' ||
      conc == 'action_required';
}

Future<String?> _fetchSingleJobLog(
  Map<dynamic, dynamic> job,
  Future<String> Function(String) ghRepoApi,
) async {
  final jobId = job['id']?.toString();
  if (jobId == null || jobId.isEmpty) return null;

  try {
    final jobLog = await ghRepoApi('actions/jobs/$jobId/logs');
    if (jobLog.trim().isEmpty) return null;
    final jobName = job['name']?.toString() ?? 'Job';
    return '--- Job: $jobName (ID: $jobId) ---\n$jobLog';
  } catch (_) {
    return null;
  }
}
