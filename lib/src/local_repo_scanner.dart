import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_utils.dart';

/// Information about a discovered local Git repository.
typedef LocalRepoInfo = ({
  String repoName,
  String repoPath,
  String? currentBranch,
  List<LocalBranchEntry> branches,
  List<LocalWorktreeEntry> worktrees,
});

/// Information about a branch in a local Git repository.
typedef LocalBranchEntry = ({String name, String sha});

/// Information about a registered Git worktree.
typedef LocalWorktreeEntry = ({String path, String branch, String sha});

/// Checks if [dir] is a Git repository or linked worktree root.
bool isGitRepository(Directory dir) {
  final gitType = FileSystemEntity.typeSync('${dir.path}/.git');
  return gitType != FileSystemEntityType.notFound;
}

/// Normalizes a remote Git URL (SSH or HTTPS) to `owner/repo`.
String? normalizeRepoName(String raw) {
  var url = raw.trim();
  if (url.startsWith('git@github.com:')) {
    url = url.substring('git@github.com:'.length);
  } else if (url.startsWith('https://github.com/')) {
    url = url.substring('https://github.com/'.length);
  } else if (url.startsWith('ssh://git@github.com/')) {
    url = url.substring('ssh://git@github.com/'.length);
  } else {
    return null;
  }
  if (url.endsWith('.git')) {
    url = url.substring(0, url.length - 4);
  }
  return url.trim();
}

/// Recursively scans [root] for Git repositories and worktrees, stopping
/// traversal in any folder once a Git repository is discovered.
///
/// Directories starting with `.` (hidden/caches) are skipped immediately.
/// Traversal terminates if [maxDepth] is exceeded (default: 6).
List<LocalRepoInfo> scanLocalGitRepositories(
  Directory root, {
  int maxDepth = 6,
  SyncProcessRunner? processRunner,
}) {
  final runner = processRunner ?? defaultSyncProcessRunner;
  final repos = <LocalRepoInfo>[];

  void walk(Directory dir, int depth) {
    if (depth > maxDepth) return;
    if (p.basename(dir.path).startsWith('.')) return;

    if (isGitRepository(dir)) {
      final info = _indexRepository(dir, runner);
      if (info != null) repos.add(info);
      return;
    }

    _walkSubdirectories(dir, depth, walk);
  }

  if (root.existsSync()) {
    walk(root, 1);
  }

  return repos;
}

void _walkSubdirectories(
  Directory dir,
  int depth,
  void Function(Directory, int) walk,
) {
  try {
    for (final sub in dir.listSync().whereType<Directory>()) {
      if (!p.basename(sub.path).startsWith('.')) {
        walk(sub, depth + 1);
      }
    }
  } catch (_) {
    // Ignore unreadable directories
  }
}

LocalRepoInfo? _indexRepository(Directory dir, SyncProcessRunner runner) {
  final originResult = runner('git', [
    'remote',
    'get-url',
    'origin',
  ], workingDirectory: dir.path);

  if (originResult.exitCode != 0) return null;

  final repoName = normalizeRepoName(originResult.stdout as String);
  if (repoName == null) return null;

  final branches = _parseBranchRefs(dir.path, runner);
  final worktrees = _parseWorktrees(dir.path, runner);

  return (
    repoName: repoName,
    repoPath: dir.path,
    currentBranch: _getCurrentBranch(dir.path, runner),
    branches: branches,
    worktrees: worktrees,
  );
}

String? _getCurrentBranch(String repoPath, SyncProcessRunner runner) {
  final branchResult = runner('git', [
    'branch',
    '--show-current',
  ], workingDirectory: repoPath);
  if (branchResult.exitCode != 0) return null;
  final out = (branchResult.stdout as String).trim();
  return out.isNotEmpty ? out : null;
}

List<LocalBranchEntry> _parseBranchRefs(
  String repoPath,
  SyncProcessRunner runner,
) {
  final branchResult = runner('git', [
    'for-each-ref',
    '--format=%(refname:short)\t%(objectname)',
    'refs/heads/',
  ], workingDirectory: repoPath);
  if (branchResult.exitCode != 0) return const [];

  final branches = <LocalBranchEntry>[];
  for (final line in (branchResult.stdout as String).trim().split('\n')) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length == 2) {
      branches.add((name: parts[0], sha: parts[1]));
    }
  }
  return branches;
}

List<LocalWorktreeEntry> _parseWorktrees(
  String repoPath,
  SyncProcessRunner runner,
) {
  final wtResult = runner('git', [
    'worktree',
    'list',
    '--porcelain',
  ], workingDirectory: repoPath);
  if (wtResult.exitCode != 0) return const [];

  final worktrees = <LocalWorktreeEntry>[];
  String? currentWtPath;
  String? currentBranch;
  String? currentSha;

  void flush() {
    if (currentWtPath != null && currentBranch != null) {
      worktrees.add((
        path: currentWtPath!,
        branch: currentBranch!,
        sha: currentSha ?? '',
      ));
    }
    currentWtPath = null;
    currentBranch = null;
    currentSha = null;
  }

  for (final line in (wtResult.stdout as String).trim().split('\n')) {
    if (line.startsWith('worktree ')) {
      currentWtPath = line.substring('worktree '.length).trim();
    } else if (line.startsWith('HEAD ')) {
      currentSha = line.substring('HEAD '.length).trim();
    } else if (line.startsWith('branch refs/heads/')) {
      currentBranch = line.substring('branch refs/heads/'.length).trim();
    } else if (line.isEmpty) {
      flush();
    }
  }
  flush();
  return worktrees;
}
