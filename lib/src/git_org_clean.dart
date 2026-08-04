// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart';
import 'package:pool/pool.dart';

import 'testable_print.dart';
import 'util.dart';

part 'git_org_clean.g.dart';

@CliOptions()
class CleanArgs {
  @CliOption(abbr: 'o', help: 'The target GitHub organization.')
  final String? org;

  @CliOption(abbr: 'h', negatable: false, help: 'Print this usage information.')
  final bool help;

  new({this.org, this.help = false}) {
    if (!help && (org == null || org!.isEmpty)) {
      throw UsageException(
        'Missing target GitHub organization!',
        'git-org-clean --org <org-name>',
      );
    }
  }
}

String get cleanArgsUsage => _$parserForCleanArgs.usage;

Future<void> runGitOrgClean(CleanArgs args, {DateTime? now}) async {
  final currentTime = now ?? DateTime.now();
  final org = args.org!;

  print('Scanning organization "$org" using gh...');

  final repos = await _fetchOrgRepos(org);
  if (repos == null) return;

  if (repos.isEmpty) {
    print('No repositories found in organization "$org".');
    return;
  }

  final hasPrivate = repos.any((r) => r['isPrivate'] == true);
  if (!hasPrivate) {
    print(
      yellow.wrap(
        'Note: No private repositories were found. If this organization '
        'has private repositories, you may need to run '
        '`gh auth refresh -s repo` to access them.',
      ),
    );
    print('');
  }

  final (:forks, :stale, :active, :archived) = _categorizeRepos(
    repos,
    currentTime,
  );

  final oldestForks = forks.take(50).toList();
  await _checkOldestForksSync(org, oldestForks);

  final safeForks = <Map<String, dynamic>>[];
  final unsafeForks = <Map<String, dynamic>>[];

  for (final repo in oldestForks) {
    final status = repo['unsyncedStatus'] as String? ?? 'Not checked';
    if (status == 'Synced') {
      safeForks.add(repo);
    } else {
      unsafeForks.add(repo);
    }
  }

  final buffer = StringBuffer()
    ..writeln('# GitHub Org Cleanup Report: $org')
    ..writeln(
      'Generated on: ${currentTime.toLocal().toString().split('.').first}',
    )
    ..writeln()
    ..writeln('## Summary')
    ..writeln('- **Total Repositories**: ${repos.length}')
    ..writeln('- **Forks**: ${forks.length}')
    ..writeln('- **Stale Repos (> 1 year since push)**: ${stale.length}')
    ..writeln('- **Already Archived**: ${archived.length}')
    ..writeln('- **Active Repos**: ${active.length}')
    ..writeln();

  _writeSafeForks(buffer, safeForks, currentTime);
  _writeUnsafeForks(buffer, unsafeForks, currentTime);
  _writeStaleRepos(buffer, stale, currentTime);
  _writeActiveAndArchived(buffer, active, archived, currentTime);

  print(buffer.toString());
}

Future<List<Map<String, dynamic>>?> _fetchOrgRepos(String org) async {
  try {
    final output = await runProcess('gh', [
      'repo',
      'list',
      org,
      '--limit',
      '1000',
      '--json',
      'name,isFork,pushedAt,isArchived,isPrivate,url,parent,viewerPermission',
    ]);
    final decoded = jsonDecode(output);
    if (decoded is! List) {
      throw const FormatException('Expected a list of repositories from gh');
    }
    return decoded.cast<Map<String, dynamic>>();
  } on ProcessException catch (e) {
    if (e.message.contains('check your internet connection') ||
        e.message.contains('not authenticated') ||
        e.message.contains('scopes')) {
      setError(
        message:
            'GitHub CLI failed to list repositories.\n'
            'Please ensure you are authenticated by running:\n'
            '  gh auth login\n'
            'Or refresh scopes if you lack access:\n'
            '  gh auth refresh -s repo,read:org\n\n'
            'Error: ${e.message}',
        exitCode: ExitCode.tempFail.code,
      );
      return null;
    }
    setError(
      message: 'Failed to run gh: ${e.message}',
      exitCode: ExitCode.software.code,
    );
    return null;
  } catch (e) {
    setError(
      message: 'Unexpected error fetching repositories: $e',
      exitCode: ExitCode.software.code,
    );
    return null;
  }
}

typedef _CategorizedRepos = ({
  List<Map<String, dynamic>> forks,
  List<Map<String, dynamic>> stale,
  List<Map<String, dynamic>> active,
  List<Map<String, dynamic>> archived,
});

_CategorizedRepos _categorizeRepos(
  List<Map<String, dynamic>> repos,
  DateTime currentTime,
) {
  final forks = <Map<String, dynamic>>[];
  final stale = <Map<String, dynamic>>[];
  final active = <Map<String, dynamic>>[];
  final archived = <Map<String, dynamic>>[];

  for (final repo in repos) {
    if (repo['isArchived'] == true) {
      archived.add(repo);
      continue;
    }

    final pushedAtStr = repo['pushedAt'] as String?;
    final pushedAt = pushedAtStr != null && pushedAtStr.isNotEmpty
        ? DateTime.tryParse(pushedAtStr)
        : null;

    final isFork = repo['isFork'] == true;
    final isStale =
        pushedAt != null && currentTime.difference(pushedAt).inDays > 365;

    if (isFork) {
      forks.add(repo);
    } else if (isStale) {
      stale.add(repo);
    } else {
      active.add(repo);
    }
  }

  forks.sort((a, b) {
    final aPushed = a['pushedAt'] as String? ?? '';
    final bPushed = b['pushedAt'] as String? ?? '';
    return aPushed.compareTo(bPushed);
  });

  stale.sort((a, b) {
    final aPushed = a['pushedAt'] as String? ?? '';
    final bPushed = b['pushedAt'] as String? ?? '';
    return aPushed.compareTo(bPushed);
  });

  return (forks: forks, stale: stale, active: active, archived: archived);
}

Future<void> _checkOldestForksSync(
  String org,
  List<Map<String, dynamic>> oldestForks,
) async {
  if (oldestForks.isEmpty) return;

  print('Checking branch sync status for the oldest forks...');
  final forkPool = Pool(3);
  final forkFutures = <Future<void>>[];

  for (final repo in oldestForks) {
    final parent = repo['parent'] as Map<String, dynamic>?;
    if (parent != null) {
      forkFutures.add(
        forkPool.withResource(() async {
          final status = await _checkForkSync(
            org,
            repo['name'] as String,
            parent,
          );
          repo['unsyncedStatus'] = status;
        }),
      );
    } else {
      repo['unsyncedStatus'] = 'No parent info';
    }
  }
  await Future.wait(forkFutures);
}

String _timeAgo(String? dateStr, DateTime currentTime) {
  if (dateStr == null || dateStr.isEmpty) return 'never';
  final parsed = DateTime.tryParse(dateStr);
  if (parsed == null) return dateStr;
  final diff = currentTime.difference(parsed);
  if (diff.inDays > 365) {
    final years = (diff.inDays / 365).floor();
    return "$years year${years > 1 ? 's' : ''} ago";
  }
  if (diff.inDays > 30) {
    final months = (diff.inDays / 30).floor();
    return "$months month${months > 1 ? 's' : ''} ago";
  }
  if (diff.inDays > 0) {
    return "${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago";
  }
  return 'today';
}

String _formatRepoName(Map<String, dynamic> repo) {
  final name = repo['name'] as String;
  final url = repo['url'] as String? ?? '';
  final visibility = repo['isPrivate'] == true ? 'private' : 'public';
  return '[$name]($url) ($visibility)';
}

String _isActionable(Map<String, dynamic> repo) {
  final perm = repo['viewerPermission'] as String?;
  return perm == 'ADMIN' ? 'Yes (Admin)' : 'No ($perm)';
}

void _writeSafeForks(
  StringBuffer buffer,
  List<Map<String, dynamic>> safeForks,
  DateTime currentTime,
) {
  if (safeForks.isEmpty) return;

  buffer
    ..writeln('## 🟢 Slam Dunk: Safe to Delete (Forks fully synced)')
    ..writeln(
      'These forks have no unsynced branches/commits relative '
      'to upstream. You can delete them safely. (Ordered oldest-push first)',
    )
    ..writeln()
    ..writeln('| Repository | Upstream | Last Push | Actionable? |')
    ..writeln('| :--- | :--- | :--- | :--- |');

  for (final repo in safeForks) {
    final upstream =
        _upstreamRepo(repo['parent'] as Map<String, dynamic>?) ??
        '(Inaccessible)';
    buffer.writeln(
      '| ${_formatRepoName(repo)} | `$upstream` | '
      '${_timeAgo(repo['pushedAt'] as String?, currentTime)} | '
      '${_isActionable(repo)} |',
    );
  }
  buffer.writeln();
}

void _writeUnsafeForks(
  StringBuffer buffer,
  List<Map<String, dynamic>> unsafeForks,
  DateTime currentTime,
) {
  if (unsafeForks.isEmpty) return;

  buffer
    ..writeln('## ⚠️ Forks with Unsynced Changes (Review Required)')
    ..writeln(
      'These forks have one or more branches with commits not '
      'present upstream. Review before deleting. (Ordered oldest-push first)',
    )
    ..writeln()
    ..writeln(
      '| Repository | Upstream | Last Push | Unsynced Branches | '
      'Actionable? |',
    )
    ..writeln('| :--- | :--- | :--- | :--- | :--- |');

  for (final repo in unsafeForks) {
    final upstream =
        _upstreamRepo(repo['parent'] as Map<String, dynamic>?) ??
        '(Inaccessible)';
    final unsynced = repo['unsyncedStatus'] as String? ?? 'Not checked';
    buffer.writeln(
      '| ${_formatRepoName(repo)} | `$upstream` | '
      '${_timeAgo(repo['pushedAt'] as String?, currentTime)} | $unsynced | '
      '${_isActionable(repo)} |',
    );
  }
  buffer.writeln();
}

void _writeStaleRepos(
  StringBuffer buffer,
  List<Map<String, dynamic>> stale,
  DateTime currentTime,
) {
  if (stale.isEmpty) return;

  buffer
    ..writeln('## 💤 Recommended for Archiving (Stale Repositories)')
    ..writeln(
      'Repositories with no push activity in over 365 days. '
      '(Ordered oldest-push first)',
    )
    ..writeln()
    ..writeln('| Repository | Last Push | Actionable? | Description |')
    ..writeln('| :--- | :--- | :--- | :--- |');

  for (final repo in stale) {
    final desc = repo['description'] as String? ?? '';
    buffer.writeln(
      '| ${_formatRepoName(repo)} | '
      '${_timeAgo(repo['pushedAt'] as String?, currentTime)} | '
      '${_isActionable(repo)} | $desc |',
    );
  }
  buffer.writeln();
}

void _writeActiveAndArchived(
  StringBuffer buffer,
  List<Map<String, dynamic>> active,
  List<Map<String, dynamic>> archived,
  DateTime currentTime,
) {
  if (active.isEmpty && archived.isEmpty) return;

  buffer
    ..writeln('## ✅ Active or Already Archived Repositories')
    ..writeln('(Listed here for completeness)')
    ..writeln();

  if (active.isNotEmpty) {
    buffer.writeln('### Active Repositories (Pushed in last 365 days)');
    for (final repo in active) {
      buffer.writeln(
        '- ${_formatRepoName(repo)} - Last push '
        '${_timeAgo(repo['pushedAt'] as String?, currentTime)}',
      );
    }
    buffer.writeln();
  }

  if (archived.isNotEmpty) {
    buffer.writeln('### Already Archived Repositories');
    for (final repo in archived) {
      buffer.writeln('- ${_formatRepoName(repo)}');
    }
    buffer.writeln();
  }
}

String? _upstreamRepo(Map<String, dynamic>? parent) => switch (parent) {
  {'owner': {'login': final String owner}, 'name': final String name} =>
    '$owner/$name',
  _ => null,
};

Future<String> _checkForkSync(
  String org,
  String forkName,
  Map<String, dynamic> parent,
) async {
  final upstreamRepo = _upstreamRepo(parent);
  if (upstreamRepo == null) {
    return 'Unknown upstream';
  }

  try {
    // 1. Get default branch of parent
    final parentInfoRaw = await runProcess('gh', [
      'api',
      'repos/$upstreamRepo',
    ]);
    final parentInfo = jsonDecode(parentInfoRaw) as Map<String, dynamic>;
    final defaultBranch = parentInfo['default_branch'] as String? ?? 'main';

    // 2. Get fork branches
    final branchesRaw = await runProcess('gh', [
      'api',
      'repos/$org/$forkName/branches',
    ]);
    final branches = jsonDecode(branchesRaw) as List;

    final unsynced = <String>[];
    final pool = Pool(5);

    final futures = branches.map((branchObj) async {
      final branchMap = branchObj as Map<String, dynamic>;
      final branchName = branchMap['name'] as String?;
      if (branchName == null) return;

      await pool.withResource(() async {
        try {
          final compareRaw = await runProcess('gh', [
            'api',
            'repos/$upstreamRepo/compare/$defaultBranch...$org:$branchName',
          ]);
          final compare = jsonDecode(compareRaw) as Map<String, dynamic>;
          final aheadBy = compare['ahead_by'] as int? ?? 0;
          if (aheadBy > 0) {
            unsynced.add('$branchName (ahead by $aheadBy)');
          }
        } catch (_) {}
      });
    });

    await Future.wait(futures);

    if (unsynced.isEmpty) {
      return 'Synced';
    }
    return unsynced.join(', ');
  } on ProcessException catch (e) {
    return 'Inaccessible: ${e.message.split('\n').first}';
  } catch (_) {
    return 'Status check failed';
  }
}
