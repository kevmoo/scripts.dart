// https://github.com/flutter/flutter/issues/161460
// https://github.com/flutter/flutter/issues/181433
// Those two issues list a BUNCH of "notable commits" in Flutter using a bunch
// of commetns to the parent issue.

// The GOAL: write a script to go through all of the commits from 2025
// and 2026 that correspond to changes AFTER Flutter 3.32
// up until the latest stable cut-off which includes commit to flutter
// ef44a7c3cef6fee67fbe29d4944632d8188d3ba7

// Then I want to filter the commetns by ones related to FLutter web
// But starting with the notable commits would be GREAT
// Do you have enough to start on?
// I could give you access
// The flutter repository is on my local machine at /Users/kevmoo/github/flutter
// I DO NOT want you to change ANYTHING there, including changing braches
// but if doing non-destrictive git operations over my local checkout is faster
// than hitting github with the gh command, pleas do it

import 'dart:convert';
import 'dart:io';

const flutterRepo = '/Users/kevmoo/github/flutter';
const targetCommit = 'ef44a7c3cef6fee67fbe29d4944632d8188d3ba7';
const startTag = '3.32.0';

const issues = [161460, 181433];

void main() async {
  print('Starting notable commits analysis...');

  for (final issue in issues) {
    final cacheFile = File('tool/issue_${issue}_comments.json');
    List<dynamic> comments;

    if (await cacheFile.exists()) {
      print('Using cached comments for issue $issue');
      comments = jsonDecode(await cacheFile.readAsString()) as List<dynamic>;
    } else {
      print('Fetching comments for issue $issue from GitHub...');
      final result = await Process.run('gh', [
        'issue',
        'view',
        issue.toString(),
        '-R',
        'flutter/flutter',
        '--json',
        'comments',
      ]);

      if (result.exitCode != 0) {
        print('Failed to fetch issue $issue: ${result.stderr}');
        continue;
      }

      final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      comments = data['comments'] as List<dynamic>;
      await cacheFile.writeAsString(jsonEncode(comments));
      print('Cached comments for issue $issue');
    }

    print('Processing ${comments.length} comments in issue $issue');

    for (final comment in comments) {
      final body = comment['body'] as String;
      final author = comment['author']['login'] as String;

      // Extract PRs and Commits (deduplicate with toSet)
      final prs = extractPrs(body).toSet();
      final directCommits = extractCommits(body).toSet();

      final allCommits = <String>{};

      for (final pr in prs) {
        print('Looking for commit for PR #$pr');
        final commit = await findCommitForPr(pr);
        if (commit != null) {
          print('  Found commit: $commit');
          allCommits.add(commit);
        } else {
          print('  Commit not found for PR #$pr');
        }
      }

      for (final commit in directCommits) {
        print('Found direct commit link: $commit');
        allCommits.add(commit);
      }

      for (final commit in allCommits) {
        print('Checking commit: $commit');
        // Check date and range
        final inRange = await isCommitInRange(commit);
        print('  In range: $inRange');
        if (!inRange) continue;

        // Check web relatedness
        final isWeb = await isWebRelated(commit, body);
        print('  Is web: $isWeb');
        if (!isWeb) continue;

        print('--- MATCH ---');
        print('Issue: $issue');
        print('Author: $author');
        print('Commit: $commit');
        print('Comment: $body');
      }
    }
  }
}

List<String> extractPrs(String text) {
  final regExp = RegExp(r'github\.com/flutter/flutter/pull/(\d+)');
  final matches = regExp.allMatches(text);
  return matches.map((m) => m.group(1)!).toList();
}

List<String> extractCommits(String text) {
  final regExp = RegExp(r'github\.com/flutter/flutter/commit/([a-f0-9]{40})');
  final matches = regExp.allMatches(text);
  return matches.map((m) => m.group(1)!).toList();
}

Future<String?> findCommitForPr(String prNumber) async {
  final result = await Process.run('git', [
    '-C',
    flutterRepo,
    'log',
    '--grep=(#$prNumber)',
    '-1',
    '--format=%H',
  ]);

  if (result.exitCode == 0) {
    final output = (result.stdout as String).trim();
    if (output.isNotEmpty) return output;
  }
  return null;
}

Future<bool> isCommitInRange(String commit) async {
  // Check if commit is ancestor of targetCommit
  final ancestorOfTarget = await Process.run('git', [
    '-C',
    flutterRepo,
    'merge-base',
    '--is-ancestor',
    commit,
    targetCommit,
  ]);

  print('    is ancestor of target: ${ancestorOfTarget.exitCode == 0}');
  if (ancestorOfTarget.exitCode != 0) return false;

  // Check if commit is ancestor of startTag (we want to EXCLUDE these)
  final ancestorOfStart = await Process.run('git', [
    '-C',
    flutterRepo,
    'merge-base',
    '--is-ancestor',
    commit,
    startTag,
  ]);

  print('    is ancestor of start: ${ancestorOfStart.exitCode == 0}');
  if (ancestorOfStart.exitCode == 0) return false;

  return true;
}

Future<bool> isWebRelated(String commit, String commentBody) async {
  if (commentBody.toLowerCase().contains('web')) return true;

  final result = await Process.run('git', [
    '-C',
    flutterRepo,
    'log',
    '-1',
    '--format=%s%b',
    commit,
  ]);

  if (result.exitCode == 0) {
    final msg = result.stdout as String;
    if (msg.toLowerCase().contains('web')) return true;
  }

  final filesResult = await Process.run('git', [
    '-C',
    flutterRepo,
    'diff-tree',
    '--no-commit-id',
    '--name-only',
    '-r',
    commit,
  ]);

  if (filesResult.exitCode == 0) {
    final files = filesResult.stdout as String;
    if (files.toLowerCase().contains('web')) return true;
  }

  return false;
}
