import 'dart:convert';
import 'dart:io';

import 'gh_view/github_queries.dart';
import 'gh_view/markdown_renderer.dart';
import 'gh_view/models.dart';
import 'gh_view/terminal_and_json_renderer.dart';
import 'local_repo_scanner.dart';
import 'process_utils.dart';

export 'gh_view/github_queries.dart' show fetchOpenPullRequests, parsePrNode;
export 'gh_view/markdown_renderer.dart' show renderMarkdownReport;
export 'gh_view/models.dart'
    show
        CiStatus,
        GhPr,
        GhPrStatus,
        GhViewException,
        GhViewOptions,
        LocalBranchStatus,
        MergeStateStatus,
        MergeableState,
        ReviewDecision,
        TouchedColor,
        categorizePullRequests,
        formatTimeAgo,
        formatTouchedMarkdown,
        formatTouchedTerminal,
        getTouchedColor;
export 'gh_view/terminal_and_json_renderer.dart'
    show renderJsonOutput, renderTerminalReport;
export 'local_repo_scanner.dart' show normalizeRepoName;
export 'shared/gh_pr_ref.dart' show GhPrRef;

/// Function signature for running an external enricher command with stdin JSON
/// payload.
typedef EnricherRunner = Future<String?> Function(
  String command,
  String stdinPayload,
);

/// Default enricher runner invoking `/bin/sh -c <command>` and piping [stdinPayload].
Future<String?> defaultEnricherRunner(
  String command,
  String stdinPayload,
) async {
  try {
    final process = await Process.start('/bin/sh', ['-c', command]);
    process.stdin.write(stdinPayload);
    await process.stdin.flush();
    await process.stdin.close();

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );

    if (exitCode != 0) {
      return null;
    }

    return await stdoutFuture;
  } catch (_) {
    return null;
  }
}

/// Invokes the [enricherCommand] and parses the returned JSON map.
Future<Map<String, String>> fetchEnrichedContext({
  required String enricherCommand,
  required List<GhPr> prs,
  EnricherRunner? enricherRunner,
}) async {
  if (prs.isEmpty) return const {};
  final runner = enricherRunner ?? defaultEnricherRunner;
  final payload = jsonEncode({
    'prs': prs
        .map(
          (pr) => {
            'number': pr.number,
            'title': pr.title,
            'url': pr.url,
            'repository': pr.repository,
            'headRefName': pr.headRefName,
            'baseRefName': pr.baseRefName,
            'isDraft': pr.isDraft,
          },
        )
        .toList(),
  });

  final rawOutput = await runner(enricherCommand, payload);
  if (rawOutput == null || rawOutput.trim().isEmpty) {
    return const {};
  }

  try {
    final decoded = jsonDecode(rawOutput);
    if (decoded is Map) {
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value?.toString().trim();
        if (key.isNotEmpty && value != null && value.isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    }
  } catch (_) {
    // Non-fatal JSON parse failure
  }
  return const {};
}

String? _lookupContext(GhPr pr, Map<String, String>? contextMap) {
  if (contextMap == null || contextMap.isEmpty) return null;
  return contextMap[pr.url] ??
      contextMap['${pr.repository}#${pr.number}'] ??
      contextMap['#${pr.number}'];
}

/// Main execution function for `gh-view`.
Future<void> runGhView({
  required GhViewOptions options,
  ProcessRunner? processRunner,
  EnricherRunner? enricherRunner,
  DateTime? now,
}) async {
  final runner = processRunner ?? Process.run;
  final currentTime = now ?? DateTime.now();

  var rawPrs = await fetchOpenPullRequests(
    user: options.user,
    repo: options.repo,
    limit: options.limit,
    lastNDays: options.lastNDays,
    currentTime: currentTime,
    processRunner: runner,
  );

  if (options.lastNDays != null) {
    final cutoff = currentTime.subtract(Duration(days: options.lastNDays!));
    rawPrs = rawPrs.where((pr) => !pr.updatedAt.isBefore(cutoff)).toList();
  }

  Map<String, String>? contextMap;
  if (options.enricher != null && options.enricher!.trim().isNotEmpty) {
    contextMap = await fetchEnrichedContext(
      enricherCommand: options.enricher!,
      prs: rawPrs,
      enricherRunner: enricherRunner,
    );
  }

  final localRepos = options.checkLocal
      ? await _discoverLocalRepositories(options.localRoot)
      : null;
  final prs = await Future.wait(
    rawPrs.map(
      (pr) => _attachLocalStatus(
        pr,
        localRepos,
        context: _lookupContext(pr, contextMap),
        processRunner: runner,
      ),
    ),
  );

  if (options.json) {
    print(renderJsonOutput(prs, currentTime: currentTime));
  } else if (options.markdown) {
    print(renderMarkdownReport(prs, currentTime: currentTime));
  } else {
    print(renderTerminalReport(prs, currentTime: currentTime));
  }
}

Future<List<LocalRepoInfo>?> _discoverLocalRepositories(
  String? customRoot, {
  SyncProcessRunner? processRunner,
}) async {
  final localRootPath =
      customRoot ?? '${Platform.environment['HOME'] ?? ''}/github';
  if (localRootPath.isNotEmpty && Directory(localRootPath).existsSync()) {
    return scanLocalGitRepositories(
      Directory(localRootPath),
      processRunner: processRunner,
    );
  }
  return null;
}

Future<GhPr> _attachLocalStatus(
  GhPr pr,
  List<LocalRepoInfo>? localRepos, {
  String? context,
  ProcessRunner? processRunner,
}) async => GhPr(
  number: pr.number,
  title: pr.title,
  url: pr.url,
  author: pr.author,
  isDraft: pr.isDraft,
  state: pr.state,
  reviewDecision: pr.reviewDecision,
  requestedReviewers: pr.requestedReviewers,
  activeReviewers: pr.activeReviewers,
  totalReviewThreads: pr.totalReviewThreads,
  unresolvedReviewThreads: pr.unresolvedReviewThreads,
  lastAuthorCommentAt: pr.lastAuthorCommentAt,
  lastReviewerActivityAt: pr.lastReviewerActivityAt,
  mergeable: pr.mergeable,
  mergeStateStatus: pr.mergeStateStatus,
  isInMergeQueue: pr.isInMergeQueue,
  headRefName: pr.headRefName,
  headRefOid: pr.headRefOid,
  baseRefName: pr.baseRefName,
  repository: pr.repository,
  repoUrl: pr.repoUrl,
  isRepoArchived: pr.isRepoArchived,
  ciStatus: pr.ciStatus,
  updatedAt: pr.updatedAt,
  localStatus: await _matchLocalStatus(
    pr,
    localRepos,
    processRunner: processRunner,
  ),
  context: context ?? pr.context,
);

Future<LocalBranchStatus?> _matchLocalStatus(
  GhPr pr,
  List<LocalRepoInfo>? localRepos, {
  ProcessRunner? processRunner,
}) async {
  if (localRepos == null || localRepos.isEmpty) return null;

  final repoKey = pr.repository.toLowerCase();
  final matchingRepos = localRepos.where(
    (r) => r.repoNames.any((n) => n.toLowerCase() == repoKey),
  );

  final location = findLocalBranchLocation(matchingRepos, pr);
  if (location == null) return null;

  final shortSha = location.sha.length >= 7
      ? location.sha.substring(0, 7)
      : location.sha;
  final isHeadMatching =
      pr.headRefOid.isNotEmpty &&
      (location.sha == pr.headRefOid || pr.headRefOid.startsWith(location.sha));

  final isDirty = await isRepoDirty(
    location.repoPath,
    processRunner: processRunner,
  );
  var display = isHeadMatching ? '🟢 Synced' : '⚠️ Diverged';
  if (isDirty) display = '$display (Dirty)';

  return (
    repoPath: location.repoPath,
    branchName: pr.headRefName,
    shortSha: shortSha,
    isDirty: isDirty,
    isHeadMatching: isHeadMatching,
    isWorktree: location.isWorktree,
    displayStatus: display,
  );
}
