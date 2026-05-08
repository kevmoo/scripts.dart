import 'dart:convert';
import 'dart:io';

import 'package:io/ansi.dart';
import 'package:io/io.dart';

/// Exception thrown by Gerrit View tool operations.
class GerritViewException implements Exception {
  final String message;
  final int exitCode;

  GerritViewException(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}

typedef CommitDetails = ({
  String sha,
  String relativeDate,
  String changeId,
  String rawBody,
});

typedef RemoteCL = ({
  int number,
  String changeId,
  String subject,
  String status,
  String currentRevision,
  int currentRevisionNumber,
});

Future<void> runGerritView({String? gerritRepo}) async {
  final repoPath = gerritRepo == null
      ? Directory.current.absolute.path
      : Directory(gerritRepo).absolute.path;

  // 1. Validate git repository
  final checkResult = await Process.run('git', [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: repoPath);
  if (checkResult.exitCode != 0) {
    throw GerritViewException(
      'Directory "$repoPath" is not a Git repository (or git is missing).',
      exitCode: ExitCode.config.code,
    );
  }

  final actualRepoRoot = (checkResult.stdout as String).trim();

  // 1b. Validate it is a Gerrit repository
  final gerritHostResult = await Process.run('git', [
    'config',
    '--get',
    'gerrit.host',
  ], workingDirectory: actualRepoRoot);
  var isGerrit =
      gerritHostResult.exitCode == 0 &&
      (gerritHostResult.stdout as String).trim().isNotEmpty;

  String? gerritHost;

  // Try resolving from branch gerritserver config first
  final serverResult = await Process.run('git', [
    'config',
    '--get-regexp',
    r'branch\..*\.gerritserver',
  ], workingDirectory: actualRepoRoot);
  if (serverResult.exitCode == 0) {
    final lines = (serverResult.stdout as String).trim().split('\n');
    for (final line in lines) {
      if (line.isEmpty) continue;
      final lastSpace = line.lastIndexOf(' ');
      if (lastSpace != -1) {
        final url = line.substring(lastSpace + 1).trim();
        final uri = Uri.tryParse(url);
        if (uri != null && uri.host.isNotEmpty) {
          gerritHost = uri.host;
          break;
        }
      }
    }
  }

  if (gerritHost == null && isGerrit) {
    final val = (gerritHostResult.stdout as String).trim();
    if (val.toLowerCase() != 'true') {
      gerritHost = val;
    }
  }

  if (gerritHost == null) {
    final remoteUrlResult = await Process.run('git', [
      'config',
      '--get',
      'remote.origin.url',
    ], workingDirectory: actualRepoRoot);
    if (remoteUrlResult.exitCode == 0) {
      final remoteUrl = (remoteUrlResult.stdout as String).trim();
      if (remoteUrl.contains('googlesource.com') ||
          remoteUrl.contains('review.chrome')) {
        isGerrit = true;
        final uri = Uri.tryParse(remoteUrl);
        if (uri != null && uri.host.isNotEmpty) {
          gerritHost = uri.host;
        }
      }
    }
  }

  if (!isGerrit) {
    throw GerritViewException(
      'Directory "$actualRepoRoot" is not a Gerrit repository.\n'
      'Neither "gerrit.host" is configured nor is the remote origin hosted '
      'on a Gerrit server.',
      exitCode: ExitCode.config.code,
    );
  }

  gerritHost ??= 'dart-review.googlesource.com';
  if (gerritHost.endsWith('.googlesource.com') &&
      !gerritHost.endsWith('-review.googlesource.com')) {
    gerritHost = gerritHost.replaceFirst(
      '.googlesource.com',
      '-review.googlesource.com',
    );
  }

  // 2. Query open CLs owned by self
  print(styleDim.wrap('Querying active CLs from Gerrit...')!);
  final gobResult = await Process.run('gob-curl', [
    'https://$gerritHost/changes/?q=owner:self+status:open&o=CURRENT_REVISION',
  ], workingDirectory: actualRepoRoot);

  if (gobResult.exitCode != 0) {
    throw GerritViewException(
      'Failed to execute gob-curl. Is it in your PATH and authenticated?\n'
      'Error: ${gobResult.stderr}',
      exitCode: ExitCode.software.code,
    );
  }

  final rawJson = (gobResult.stdout as String).trim();
  final cleanedJson = rawJson.replaceFirst(")]}'", '').trim();

  final List<dynamic> clList;
  try {
    clList = jsonDecode(cleanedJson) as List<dynamic>;
  } catch (e) {
    throw GerritViewException(
      'Failed to parse Gerrit response: $e\nRaw output:\n$cleanedJson',
      exitCode: ExitCode.software.code,
    );
  }

  final remoteCLs = <int, RemoteCL>{};
  for (final item in clList) {
    if (item case {
      '_number': final int number,
      'change_id': final String changeId,
      'subject': final String subject,
      'status': final String status,
      'current_revision': final String currentRevision,
      'revisions': final Map<String, dynamic> revisions,
    }) {
      final currentRevisionNumber =
          (revisions[currentRevision] as Map<String, dynamic>?)?['_number']
              as int? ??
          1;

      remoteCLs[number] = (
        number: number,
        changeId: changeId,
        subject: subject,
        status: status,
        currentRevision: currentRevision,
        currentRevisionNumber: currentRevisionNumber,
      );
    }
  }

  // 3. Retrieve local branches configured with gerritissue
  final configResult = await Process.run('git', [
    'config',
    '--get-regexp',
    r'branch\..*\.gerritissue',
  ], workingDirectory: actualRepoRoot);

  final localBranchIssues = <String, int>{};
  if (configResult.exitCode == 0) {
    final lines = (configResult.stdout as String).trim().split('\n');
    for (final line in lines) {
      if (line.isEmpty) continue;
      final lastSpace = line.lastIndexOf(' ');
      if (lastSpace != -1) {
        final key = line.substring(0, lastSpace);
        final issueVal = int.tryParse(line.substring(lastSpace + 1));
        if (issueVal != null) {
          final match = RegExp(r'^branch\.(.*)\.gerritissue$').firstMatch(key);
          if (match != null) {
            final branchName = match.group(1)!;
            localBranchIssues[branchName] = issueVal;
          }
        }
      }
    }
  }

  // 4. Fetch local details for configured branches
  final branchDetails = <String, CommitDetails>{};
  for (final branch in localBranchIssues.keys) {
    final details = await _fetchCommitDetails(actualRepoRoot, branch);
    if (details != null) {
      branchDetails[branch] = details;
    }
  }

  // 4b. Detect default branch
  final defaultBranch = await _getDefaultBranch(actualRepoRoot);

  // 4c. Batch query closed/abandoned CL statuses
  final closedIssues = localBranchIssues.values
      .where((issue) => !remoteCLs.containsKey(issue))
      .toSet()
      .toList();
  final closedStatuses = await _fetchRemoteCLStatuses(
    actualRepoRoot,
    closedIssues,
  );

  // 4d. Concurrent batch shadow fetch
  final fetchRefs = <String>[];
  for (final branch in localBranchIssues.keys) {
    final issue = localBranchIssues[branch]!;
    final details = branchDetails[branch];
    final remote = remoteCLs[issue];

    if (details != null &&
        remote != null &&
        details.sha != remote.currentRevision) {
      final lastTwo = (remote.number % 100).toString().padLeft(2, '0');
      final ref =
          'refs/changes/$lastTwo/${remote.number}/${remote.currentRevisionNumber}';
      fetchRefs.add(ref);
    }
  }

  if (fetchRefs.isNotEmpty) {
    print(styleDim.wrap('Fetching remote changes from Gerrit...')!);
    final fetchResult = await Process.start(
      'git',
      ['fetch', 'origin', ...fetchRefs],
      workingDirectory: actualRepoRoot,
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await fetchResult.exitCode;
    if (exitCode != 0) {
      print(
        yellow.wrap(
          'Warning: Batch fetch failed. Alignment checks will use local cache.',
        )!,
      );
    }
  }

  // 5. Grouping of branches
  final alignedBranches = <String, (RemoteCL, CommitDetails, String)>{};
  final closedClBranches = <String, (int, CommitDetails, String)>{};
  final conflatedBranches = <int, List<String>>{};
  final mismatchedChangeIdBranches = <String, (RemoteCL, CommitDetails)>{};

  // Identify conflated issues (multiple branches targeting the same issue)
  final issueToBranches = <int, List<String>>{};
  for (final entry in localBranchIssues.entries) {
    issueToBranches.putIfAbsent(entry.value, () => []).add(entry.key);
  }
  for (final entry in issueToBranches.entries) {
    if (entry.value.length > 1) {
      conflatedBranches[entry.key] = entry.value;
    }
  }

  // Analyze local branches
  for (final branch in localBranchIssues.keys) {
    final issue = localBranchIssues[branch]!;
    final details = branchDetails[branch];
    if (details == null) continue;

    final remote = remoteCLs[issue];
    if (remote == null) {
      final clDetail = closedStatuses[issue] ?? 'UNKNOWN';
      closedClBranches[branch] = (issue, details, clDetail);
      continue;
    }

    // Check if Change-Id matches
    if (details.changeId != remote.changeId) {
      mismatchedChangeIdBranches[branch] = (remote, details);
      continue;
    }

    // If conflated, we deal with it in a special section
    if (conflatedBranches.containsKey(issue)) {
      continue;
    }

    // Tree and SHA alignment check using shadow fetch
    final alignmentStr = await _calculateAlignment(
      actualRepoRoot,
      branch,
      details,
      remote,
    );

    alignedBranches[branch] = (remote, details, alignmentStr);
  }

  // Find Remote-Only CLs (open CLs on remote with no local branch)
  final remoteOnlyCLs = <int, RemoteCL>{};
  final mappedIssues = localBranchIssues.values.toSet();
  for (final cl in remoteCLs.values) {
    if (!mappedIssues.contains(cl.number)) {
      remoteOnlyCLs[cl.number] = cl;
    }
  }

  // 6. Output dashboard report
  print('''

======================================================================
${styleBold.wrap('🔍 GERRIT WORKSPACE OVERVIEW')}
${styleDim.wrap('Repository: $actualRepoRoot')}
======================================================================
''');

  // SECTION 1: Perfectly Aligned Branches
  if (alignedBranches.isNotEmpty) {
    print(styleBold.wrap('✅ ACTIVE & ALIGNED LOCAL BRANCHES')!);
    for (final entry in alignedBranches.entries) {
      final branch = entry.key;
      final (remote, details, alignment) = entry.value;
      print('''
  • ${styleBold.wrap(branch)} ➔ CL ${remote.number} (${styleDim.wrap(remote.subject)})
    URL:        https://dart-review.googlesource.com/c/sdk/+/${remote.number}
    Alignment:  $alignment
    Last Touch: ${details.relativeDate}
''');
    }
  }

  // SECTION 2: Remote-Only CLs (Cleanup/Checkout Candidates)
  if (remoteOnlyCLs.isNotEmpty) {
    print(styleBold.wrap('🌐 REMOTE-ONLY CLS (No local branch tracking)')!);
    print(
      styleDim.wrap(
        '   These open CLs are on Gerrit but have no corresponding '
        'local branch:',
      )!,
    );
    for (final cl in remoteOnlyCLs.values) {
      print('''
  • CL ${cl.number}: ${cl.subject}
    URL:        https://dart-review.googlesource.com/c/sdk/+/${cl.number}
''');
    }
  }

  // SECTION 3: Conflated & Mismatched Branches (Immediate Action Needed)
  if (conflatedBranches.isNotEmpty || mismatchedChangeIdBranches.isNotEmpty) {
    print(red.wrap(styleBold.wrap('⚠️  CONFLATED OR MISMATCHED BRANCHES')!)!);
    print(
      styleDim.wrap(
        '   These branches have conflicting configuration or divergent '
        'Change-Ids:',
      )!,
    );
    print('');

    // Conflated issues
    for (final entry in conflatedBranches.entries) {
      final issue = entry.key;
      final branchesList = entry.value;
      final remote = remoteCLs[issue];
      final subject = remote?.subject ?? 'Unknown CL';

      final urlLine = remote != null
          ? '    URL:        https://dart-review.googlesource.com/c/sdk/+/$issue\n'
          : '';
      final conflatedLabel = styleDim.wrap(
        'The following ${branchesList.length} branches target this CL:',
      );
      print('''
  ${red.wrap('• CONFLATED CL:')} $issue ($subject)
$urlLine    $conflatedLabel
    ${'Branch'.padRight(25)} ${'Change-Id'.padRight(12)} ${'Commit SHA'.padRight(12)} ${'Tree (Content)'.padRight(15)} ${'Last Commit'.padRight(15)}
    --------------------------------------------------------------------''');
      for (final branch in branchesList) {
        final details = branchDetails[branch];
        if (details == null) continue;

        var changeIdStatus = '❌ MISMATCH';
        var shaStatus = '❌ OUT OF SYNC';
        var treeStatus = '❌ DIFFERENT';

        if (remote != null) {
          if (details.changeId == remote.changeId) {
            changeIdStatus = '✅ MATCH';
          } else if (details.changeId.isNotEmpty) {
            changeIdStatus = '⚠️ OTHER CL';
          }

          final alignment = await _calculateAlignment(
            actualRepoRoot,
            branch,
            details,
            remote,
          );
          if (alignment.contains('IN SYNC')) {
            shaStatus = '✅ SYNCED';
            treeStatus = '✅ IDENTICAL';
          } else if (alignment.contains('CONTENT IDENTICAL')) {
            shaStatus = '❌ OUT OF SYNC';
            treeStatus = '✅ IDENTICAL';
          }
        }

        final branchCol = branch.padRight(25);
        final changeIdCol = changeIdStatus.padRight(12);
        final shaCol = shaStatus.padRight(12);
        final treeCol = treeStatus.padRight(15);
        final dateCol = details.relativeDate.padRight(15);
        print('    $branchCol $changeIdCol $shaCol $treeCol $dateCol');
      }
      print('');
    }

    // Mismatched Change-Ids
    for (final entry in mismatchedChangeIdBranches.entries) {
      final branch = entry.key;
      final (remote, details) = entry.value;
      print('''
  ${red.wrap('• MISMATCHED CHANGE-ID:')} ${styleBold.wrap(branch)}
    Target CL:  ${remote.number} (${remote.subject})
    URL:        https://dart-review.googlesource.com/c/sdk/+/${remote.number}
    Local ID:   ${details.changeId}
    Remote ID:  ${remote.changeId}
''');
    }
  }

  // SECTION 4: Closed/Abandoned Branches (Cleanup Candidates)
  if (closedClBranches.isNotEmpty) {
    print(
      yellow.wrap(
        styleBold.wrap('🧹 CLEANUP CANDIDATES (Closed/Abandoned CL Branches)')!,
      )!,
    );
    print(
      styleDim.wrap(
        '   These local branches point to CLs that are merged, abandoned, '
        'or closed:',
      )!,
    );
    for (final entry in closedClBranches.entries) {
      final branch = entry.key;
      final (issue, details, status) = entry.value;

      final safety = await _checkCleanupSafety(
        actualRepoRoot,
        branch,
        defaultBranch,
      );

      final String safetyStatus;
      final String actionText;

      if (branch == defaultBranch) {
        safetyStatus = yellow.wrap(
          '⚠️  Protected Default Branch (Do NOT delete this branch!)',
        )!;
        actionText =
            '    Archive:    git config --unset '
            'branch.$branch.gerritissue';
      } else if (safety.isSafe) {
        safetyStatus = green.wrap(
          '✅ Safe to delete (All changes exist in origin/$defaultBranch)',
        )!;
        actionText = '    Run:        git branch -D $branch';
      } else {
        final count = safety.unmergedShas.length;
        safetyStatus = red.wrap(
          '⚠️  Warning: Has $count unmerged commit(s) not in '
          'origin/$defaultBranch!',
        )!;
        actionText =
            '    Inspect:    git diff origin/$defaultBranch..$branch\n'
            '    Run:        git branch -D $branch (Force discard)\n'
            '    Archive:    git config --unset branch.$branch.gerritissue';
      }

      print('''
  • ${styleBold.wrap(branch)} ➔ CL $issue [${styleBold.wrap(status)}]
    URL:        https://dart-review.googlesource.com/c/sdk/+/$issue
    Last Touch: ${details.relativeDate}
    Safety:     $safetyStatus
$actionText
''');
    }
  }
}

Future<CommitDetails?> _fetchCommitDetails(
  String repoPath,
  String branchName,
) async {
  final result = await Process.run('git', [
    'log',
    '-n',
    '1',
    '--format=COMMIT_METADATA_START%n%H%n%ar%n%B',
    branchName,
  ], workingDirectory: repoPath);
  if (result.exitCode != 0) return null;

  final output = result.stdout as String;
  if (!output.startsWith('COMMIT_METADATA_START\n')) return null;

  final lines = output.substring('COMMIT_METADATA_START\n'.length).split('\n');
  if (lines case [final String rawSha, final String rawRelativeDate, ...]) {
    final sha = rawSha.trim();
    final relativeDate = rawRelativeDate.trim();
    final rawBody = lines.sublist(2).join('\n');

    var changeId = '';
    final changeIdMatch = RegExp(
      r'^Change-Id:\s+(I[a-fA-F0-9]+)\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(rawBody);
    if (changeIdMatch != null) {
      changeId = changeIdMatch.group(1)!;
    }

    return (
      sha: sha,
      relativeDate: relativeDate,
      changeId: changeId,
      rawBody: rawBody,
    );
  }

  return null;
}

Future<Map<int, String>> _fetchRemoteCLStatuses(
  String repoPath,
  List<int> clNumbers,
) async {
  final statuses = <int, String>{};
  if (clNumbers.isEmpty) return statuses;

  final query = clNumbers.map((n) => 'change:$n').join('+OR+');
  final result = await Process.run('gob-curl', [
    'https://dart-review.googlesource.com/changes/?q=$query',
  ], workingDirectory: repoPath);

  if (result.exitCode != 0) return statuses;

  final rawJson = (result.stdout as String).trim();
  final cleanedJson = rawJson.replaceFirst(")]}'", '').trim();

  try {
    final list = jsonDecode(cleanedJson) as List<dynamic>;
    for (final item in list) {
      if (item case {
        '_number': final int number,
        'status': final String status,
      }) {
        statuses[number] = status;
      }
    }
  } catch (_) {
    // Fallback
  }

  return statuses;
}

Future<String> _calculateAlignment(
  String repoPath,
  String branchName,
  CommitDetails local,
  RemoteCL remote,
) async {
  if (local.sha == remote.currentRevision) {
    return green.wrap('✅ IN SYNC (Commit perfectly matches Gerrit latest)')!;
  }

  // Check if remote commit exists locally after batch fetch
  final remoteTreeResult = await Process.run('git', [
    'rev-parse',
    '--verify',
    '--quiet',
    '${remote.currentRevision}^{tree}',
  ], workingDirectory: repoPath);

  if (remoteTreeResult.exitCode != 0) {
    return yellow.wrap('⚠️ DIVERGED (Commit differs; shadow fetch failed)')!;
  }

  // Read local tree hash
  final localTreeResult = await Process.run('git', [
    'rev-parse',
    '$branchName^{tree}',
  ], workingDirectory: repoPath);

  if (remoteTreeResult.exitCode == 0 && localTreeResult.exitCode == 0) {
    final remoteTree = (remoteTreeResult.stdout as String).trim();
    final localTree = (localTreeResult.stdout as String).trim();

    if (remoteTree == localTree) {
      return green.wrap(
        '✅ CONTENT IDENTICAL (Commits differ, but file content matches '
        'Gerrit)',
      )!;
    }
  }

  return yellow.wrap(
    '⚠️ DIVERGED (Commits and file contents both differ from Gerrit)',
  )!;
}

typedef CleanupSafety = ({bool isSafe, List<String> unmergedShas});

Future<CleanupSafety> _checkCleanupSafety(
  String repoPath,
  String branchName,
  String defaultBranch,
) async {
  final result = await Process.run('git', [
    'cherry',
    'origin/$defaultBranch',
    branchName,
  ], workingDirectory: repoPath);

  if (result.exitCode != 0) {
    return (isSafe: false, unmergedShas: <String>[]);
  }

  final output = (result.stdout as String).trim();
  if (output.isEmpty) {
    return (isSafe: true, unmergedShas: <String>[]);
  }

  final lines = output.split('\n');
  final unmerged = <String>[];
  for (final line in lines) {
    if (line.startsWith('+ ')) {
      unmerged.add(line.substring(2).trim());
    }
  }

  return (isSafe: unmerged.isEmpty, unmergedShas: unmerged);
}

Future<String> _getDefaultBranch(String repoPath) async {
  final result = await Process.run('git', [
    'rev-parse',
    '--abbrev-ref',
    'origin/HEAD',
  ], workingDirectory: repoPath);

  if (result.exitCode == 0) {
    final output = (result.stdout as String).trim();
    if (output.startsWith('origin/')) {
      return output.substring('origin/'.length);
    }
    return output;
  }

  // Sniff fallback
  for (final branch in ['main', 'master']) {
    final check = await Process.run('git', [
      'show-ref',
      '--verify',
      '--quiet',
      'refs/remotes/origin/$branch',
    ], workingDirectory: repoPath);
    if (check.exitCode == 0) {
      return branch;
    }
  }

  return 'main';
}
