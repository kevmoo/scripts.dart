import 'dart:io';

import 'package:checks/checks.dart';
import 'package:git/git.dart';
import 'package:kevmoo_scripts/src/git_extensions.dart';
import 'package:kevmoo_scripts/src/local_repo_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('normalizeRepoName', () {
    test('normalizes SSH URLs', () {
      check(normalizeRepoName('git@github.com:owner/repo.git'))
          .equals('owner/repo');
      check(normalizeRepoName('git@github.com:owner/repo'))
          .equals('owner/repo');
    });

    test('normalizes HTTPS URLs with trailing slashes and www', () {
      check(normalizeRepoName('https://github.com/owner/repo.git'))
          .equals('owner/repo');
      check(normalizeRepoName('https://github.com/owner/repo/'))
          .equals('owner/repo');
      check(normalizeRepoName('https://www.github.com/owner/repo.git'))
          .equals('owner/repo');
      check(normalizeRepoName('http://github.com/owner/repo'))
          .equals('owner/repo');
    });

    test('normalizes ssh:// URLs', () {
      check(normalizeRepoName('ssh://git@github.com/owner/repo.git'))
          .equals('owner/repo');
    });

    test('returns null for non-GitHub URLs', () {
      check(normalizeRepoName('https://gitlab.com/owner/repo.git')).isNull();
      check(normalizeRepoName('sso://user/kevmoo/repo')).isNull();
    });
  });

  group('scanLocalGitRepositories', () {
    test('discovers depth 1 and depth 2 repos and stops at .git', () async {
      // 1. Create a top-level repo: sandbox/repo1
      await d.dir('repo1', [d.file('README.md', '# Repo 1')]).create();
      final repo1Path = p.join(d.sandbox, 'repo1');
      final git1 = await GitDir.init(repo1Path, allowContent: true);
      await git1.configureTestIdentity();
      await git1.runCommand(['branch', '-M', 'main']);
      await git1.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/external/repo1.git',
      ]);
      await git1.runCommand(['add', '.']);
      await git1.runCommand(['commit', '-m', 'init']);

      // 2. Create an attached sibling worktree: sandbox/_repo1-feat
      final wtPath = p.join(d.sandbox, '_repo1-feat');
      await git1.runCommand(['worktree', 'add', '-b', 'feat', wtPath]);

      // 3. Create a nested org folder: sandbox/kevmoo/repo2
      await d.dir('kevmoo', [
        d.dir('repo2', [d.file('README.md', '# Repo 2')]),
      ]).create();
      final repo2Path = p.join(d.sandbox, 'kevmoo', 'repo2');
      final git2 = await GitDir.init(repo2Path, allowContent: true);
      await git2.configureTestIdentity();
      await git2.runCommand(['branch', '-M', 'main']);
      await git2.runCommand([
        'remote',
        'add',
        'origin',
        'git@github.com:kevmoo/repo2.git',
      ]);
      await git2.runCommand(['add', '.']);
      await git2.runCommand(['commit', '-m', 'init']);

      // 4. Create a hidden directory with a git repo: sandbox/.hidden/repo3 (should be ignored)
      await d.dir('.hidden', [
        d.dir('repo3', [d.file('README.md', '# Repo 3')]),
      ]).create();
      final repo3Path = p.join(d.sandbox, '.hidden', 'repo3');
      final git3 = await GitDir.init(repo3Path, allowContent: true);
      await git3.configureTestIdentity();
      await git3.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/hidden/repo3.git',
      ]);

      // Scan root
      final repos = scanLocalGitRepositories(Directory(d.sandbox));

      final repoNames = repos.map((r) => r.repoName).toList();
      check(repoNames)
        ..contains('external/repo1')
        ..contains('kevmoo/repo2')
        ..not((it) => it.contains('hidden/repo3'));

      final repo1Info = repos.firstWhere((r) => r.repoName == 'external/repo1');
      check(repo1Info.worktrees.map((w) => w.branch)).contains('feat');
    });

    test('excludes repositories with Dart SDK / Gerrit remotes', () async {
      await d.dir('sdk_repo', [d.file('README.md', '# SDK')]).create();
      final sdkPath = p.join(d.sandbox, 'sdk_repo');
      final gitSdk = await GitDir.init(sdkPath, allowContent: true);
      await gitSdk.configureTestIdentity();
      await gitSdk.runCommand([
        'remote',
        'add',
        'origin',
        'https://github.com/dart-lang/sdk.git',
      ]);

      final repos = scanLocalGitRepositories(Directory(d.sandbox));
      check(repos.map((r) => r.repoName))
          .not((it) => it.contains('dart-lang/sdk'));
    });
  });

  group('isDartSdkRemote & isDartSdkRepositoryName', () {
    test('identifies Dart SDK and Gerrit remotes', () {
      check(isDartSdkRemote('https://github.com/dart-lang/sdk.git')).isTrue();
      check(isDartSdkRemote('sso://dart/sdk.git')).isTrue();
      check(isDartSdkRemote('sso://dart/sdk')).isTrue();
      check(isDartSdkRemote('https://dart.googlesource.com/sdk')).isTrue();
      check(isDartSdkRemote('https://dart-review.googlesource.com/sdk'))
          .isTrue();
      check(isDartSdkRemote('https://github.com/flutter/flutter.git'))
          .isFalse();
      check(isDartSdkRemote('https://github.com/kevmoo/scripts.dart.git'))
          .isFalse();
    });

    test('identifies Dart SDK repository names', () {
      check(isDartSdkRepositoryName('dart-lang/sdk')).isTrue();
      check(isDartSdkRepositoryName('kevmoo/sdk')).isTrue();
      check(isDartSdkRepositoryName('kevmoo/dart-sdk-bazel')).isTrue();
      check(isDartSdkRepositoryName('kevmoo/scripts.dart')).isFalse();
    });
  });

  group('isRepoDirty & isRepoDirtySync', () {
    test('accurately detects clean, modified, and untracked states', () async {
      await d.dir('dirty_test', [d.file('tracked.txt', 'hello')]).create();
      final repoPath = p.join(d.sandbox, 'dirty_test');
      final git = await GitDir.init(repoPath, allowContent: true);
      await git.configureTestIdentity();
      await git.runCommand(['add', '.']);
      await git.runCommand(['commit', '-m', 'initial']);

      // 1. Clean repo
      check(await isRepoDirty(repoPath)).isFalse();
      check(isRepoDirtySync(repoPath)).isFalse();

      // 2. Untracked file (with includeUntracked: false vs true)
      File(p.join(repoPath, 'untracked.txt')).writeAsStringSync('new content');
      check(await isRepoDirty(repoPath)).isFalse();
      check(isRepoDirtySync(repoPath)).isFalse();
      check(await isRepoDirty(repoPath, includeUntracked: true)).isTrue();
      check(isRepoDirtySync(repoPath, includeUntracked: true)).isTrue();

      // 3. Tracked modification
      File(p.join(repoPath, 'tracked.txt'))
          .writeAsStringSync('modified content');
      check(await isRepoDirty(repoPath)).isTrue();
      check(isRepoDirtySync(repoPath)).isTrue();

      // 4. Non-existent directory / process failure
      const nonExistent = '/non/existent/directory';
      check(await isRepoDirty(nonExistent)).isFalse();
      check(isRepoDirtySync(nonExistent)).isFalse();
      check(await isRepoDirty(nonExistent, failClosedOnProcessError: true))
          .isTrue();
      check(isRepoDirtySync(nonExistent, failClosedOnProcessError: true))
          .isTrue();
    });
  });
}
