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

/// Main entrypoint for `kscripts pr-cleanup`.
Future<void> runPrCleanup({
  required PrCleanupOptions options,
  SyncProcessRunner? syncProcessRunner,
  ProcessRunner? asyncProcessRunner,
  void Function(String message)? onProgress,
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

  if (options.json) {
    print(formatJsonReport(sweepResult, applied: options.apply));
  } else {
    print(formatMarkdownReport(sweepResult, applied: options.apply));
  }
}
