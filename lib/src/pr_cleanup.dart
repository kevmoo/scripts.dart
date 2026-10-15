import 'dart:io';

import 'local_repo_scanner.dart';
import 'pr_cleanup/cleanup_executor.dart';
import 'pr_cleanup/collector.dart';
import 'pr_cleanup/pr_cleanup_options.dart';
import 'pr_cleanup/report_formatter.dart';
import 'process_utils.dart';

export 'pr_cleanup/models.dart';
export 'pr_cleanup/pr_cleanup_options.dart';
export 'pr_cleanup/report_formatter.dart';

const prCleanupDescription =
    'Unified multi-repo GitHub and Gerrit PR, CL, and worktree cleanup sweep.';

/// Default local file path where `kscripts pr-cleanup` caches the latest JSON
/// sweep result for ad-hoc DuckDB / jq querying.
const defaultPrCleanupJsonCachePath = '/tmp/pr_cleanup_latest.json';

/// Main entrypoint for `kscripts pr-cleanup`.
Future<void> runPrCleanup({
  required PrCleanupOptions options,
  SyncProcessRunner? syncProcessRunner,
  ProcessRunner? asyncProcessRunner,
  void Function(String message)? onProgress,
  String? jsonCachePath = defaultPrCleanupJsonCachePath,
}) async {
  final sweepResult = await collectPrSweep(
    options: options,
    syncProcessRunner: syncProcessRunner,
    asyncProcessRunner: asyncProcessRunner,
    onProgress: onProgress,
  );

  if (options.apply && sweepResult.bucketB.isNotEmpty) {
    final rootPath =
        options.localRoot ??
        Platform.environment['GH_LOCAL_ROOT'] ??
        '${Platform.environment['HOME']}/github';
    final localRepos = scanLocalGitRepositories(
      Directory(rootPath),
      processRunner: syncProcessRunner ?? defaultSyncProcessRunner,
    );

    await executeBucketBPruning(
      bucketBItems: sweepResult.bucketB,
      localRepos: localRepos,
      dartSdkPath: options.dartSdkPath,
      syncProcessRunner: syncProcessRunner,
      onProgress: onProgress,
    );
  }

  final jsonReport = formatJsonReport(sweepResult, applied: options.apply);
  if (jsonCachePath != null && jsonCachePath.isNotEmpty) {
    try {
      File(jsonCachePath).writeAsStringSync(jsonReport);
    } catch (_) {
      // Ignore cache write errors so read-only environments never fail.
    }
  }

  if (options.json) {
    print(jsonReport);
  } else {
    print(formatMarkdownReport(sweepResult, applied: options.apply));
  }
}
