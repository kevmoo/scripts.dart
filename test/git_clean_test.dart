import 'dart:io';

import 'package:git/git.dart';
import 'package:kevmoo_scripts/src/git_clean.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  late String remotePath;
  late String localPath;
  late GitDir remoteGitDir;
  late GitDir localGitDir;

  setUp(() async {
    // 1. Create a "remote" repo
    // We use a normal repo and commit to it, to act as a remote.
    await d.dir('remote', [d.file('README.md', 'remote readme')]).create();
    remotePath = p.join(d.sandbox, 'remote');

    // Init remote as a git repo using Process.run to avoid GitDir.init
    // strictness
    await Process.run('git', [
      'init',
      '--initial-branch=main',
    ], workingDirectory: remotePath);
    await Process.run('git', [
      'config',
      'user.email',
      'test@test.com',
    ], workingDirectory: remotePath);
    await Process.run('git', [
      'config',
      'user.name',
      'Tester',
    ], workingDirectory: remotePath);
    await Process.run('git', ['add', '.'], workingDirectory: remotePath);
    await Process.run('git', [
      'commit',
      '-m',
      'Initial commit',
    ], workingDirectory: remotePath);

    remoteGitDir = await GitDir.fromExisting(remotePath);

    // 2. Clone to "local"
    localPath = p.join(d.sandbox, 'local');

    await Process.run('git', ['clone', remotePath, localPath]);

    localGitDir = await GitDir.fromExisting(localPath);
    await localGitDir.runCommand(['config', 'user.email', 'test@test.com']);
    await localGitDir.runCommand(['config', 'user.name', 'Tester']);

    // Verify setup
    expect(await localGitDir.isWorkingTreeClean(), isTrue);
  });

  test('cleans up deleted branch', () async {
    // Create branch 'feature' in local
    await localGitDir.runCommand(['checkout', '-b', 'feature']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature']);

    // Switch back to main in local
    await localGitDir.runCommand(['checkout', 'main']);

    // Now delete 'feature' in REMOTE
    await remoteGitDir.runCommand(['branch', '-D', 'feature']);

    // Run git_clean API
    await clean(localGitDir);

    // Verify 'feature' is gone in local
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), isNot(contains('feature')));
  });

  test('switches from deleted branch to main', () async {
    // Create branch 'feature-gone'
    await localGitDir.runCommand(['checkout', '-b', 'feature-gone']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'feature-gone']);

    // Delete 'feature-gone' in REMOTE
    await remoteGitDir.runCommand(['branch', '-D', 'feature-gone']);

    // Ensure we are ON 'feature-gone' locally
    final currentBr = await localGitDir.currentBranch();
    expect(currentBr.branchName, 'feature-gone');

    // Run git_clean API
    await clean(localGitDir);

    // Verify we are now on 'main'
    final newBr = await localGitDir.currentBranch();
    expect(newBr.branchName, 'main');

    // Verify 'feature-gone' is deleted
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), isNot(contains('feature-gone')));
  });

  test('does not delete protected branches (main)', () async {
    await clean(localGitDir);
    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), contains('main'));
  });

  test('does not delete other branches that are valid', () async {
    await localGitDir.runCommand(['checkout', '-b', 'keep-me']);
    await localGitDir.runCommand(['push', '-u', 'origin', 'keep-me']);
    await localGitDir.runCommand(['checkout', 'main']);

    // keep-me exists on remote, so should NOT be deleted
    await clean(localGitDir);

    final branches = await localGitDir.branches();
    expect(branches.map((b) => b.branchName), contains('keep-me'));
  });
}
