import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_utils.dart';

/// Information about a discovered local Git repository.
typedef LocalRepoInfo = ({
  String repoName,
  List<String> repoNames,
  String repoPath,
  String? currentBranch,
  List<LocalBranchEntry> branches,
  List<LocalWorktreeEntry> worktrees,
});

/// Information about a branch in a local Git repository.
typedef LocalBranchEntry = ({
  String name,
  String sha,
  String? upstream,
  String? upstreamTrack,
});

/// Extension on [LocalBranchEntry] providing tracking status inspection.
extension LocalBranchEntryExtension on LocalBranchEntry {
  /// Returns `true` if the branch tracks an upstream remote branch and is
  /// completely up to date with it (zero commits ahead or behind).
  bool get isUpToDateWithUpstream =>
      upstream != null &&
      upstream!.isNotEmpty &&
      (upstreamTrack == null || upstreamTrack!.isEmpty);
}

/// Information about a registered Git worktree.
typedef LocalWorktreeEntry = ({String path, String branch, String sha});

/// Checks if [dir] is a primary root Git repository (where `.git` is a
/// directory).
bool isRootGitRepository(Directory dir) {
  final gitType = FileSystemEntity.typeSync('${dir.path}/.git');
  return gitType == FileSystemEntityType.directory;
}

/// Checks if [dir] is either a primary Git repository or a linked worktree.
bool isGitRepository(Directory dir) {
  final gitType = FileSystemEntity.typeSync('${dir.path}/.git');
  return gitType != FileSystemEntityType.notFound;
}

/// Normalizes a remote Git URL (SSH, HTTPS, HTTP, SCP-style) to `owner/repo`.
String? normalizeRepoName(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  if (text.startsWith('git@github.com:')) {
    return _normalizeScpGitUrl(text);
  }
  return _normalizeUriGitUrl(text);
}

String? _normalizeScpGitUrl(String text) {
  final path = text.substring('git@github.com:'.length);
  final segments = p.posix
      .split(path)
      .where((s) => s.isNotEmpty && s != '.')
      .toList();
  if (segments.length != 2) return null;
  final owner = segments[0];
  var repo = segments[1];
  if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
  return repo.isNotEmpty ? '$owner/$repo' : null;
}

String? _normalizeUriGitUrl(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null) return null;

  final host = uri.host.toLowerCase();
  if (host != 'github.com' && host != 'www.github.com') return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 2) return null;

  final owner = segments[0];
  var repo = segments[1];
  if (repo.endsWith('.git')) {
    repo = repo.substring(0, repo.length - 4);
  }
  return repo.isNotEmpty ? '$owner/$repo' : null;
}

/// Recursively scans [root] for Git repositories and worktrees, stopping
/// traversal in any folder once a Git repository or worktree is discovered.
///
/// Directories starting with `.` (hidden/caches) are skipped immediately.
/// Traversal terminates if [maxDepth] is exceeded (default: 5).
List<LocalRepoInfo> scanLocalGitRepositories(
  Directory root, {
  int maxDepth = 5,
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

/// Checks if a remote Git URL points to the Dart SDK or its Gerrit remotes.
bool isDartSdkRemote(String remoteUrl) {
  final lower = remoteUrl.toLowerCase().trim();
  if (lower.isEmpty) return false;
  return lower.contains('dart-lang/sdk') ||
      lower.contains('dart.googlesource.com') ||
      lower.contains('dart-review.googlesource.com') ||
      lower.contains('sso://dart/');
}

/// Known Dart SDK GitHub repository names that should not be touched by
/// `gh-clean` (since the SDK uses Gerrit for branch and worktree lifecycles).
bool isDartSdkRepositoryName(String repoName) {
  final lower = repoName.toLowerCase().trim();
  return lower == 'dart-lang/sdk' ||
      lower == 'kevmoo/sdk' ||
      lower == 'kevmoo/dart-sdk-bazel';
}

LocalRepoInfo? _indexRepository(Directory dir, SyncProcessRunner runner) {
  final remoteResult = runner('git', [
    'remote',
    '-v',
  ], workingDirectory: dir.path);

  if (remoteResult.exitCode != 0) return null;

  final repoNames = _extractRepoNames(remoteResult.stdout as String);
  if (repoNames == null) return null;

  final branches = _parseBranchRefs(dir.path, runner);
  final worktrees = _parseWorktrees(dir.path, runner);

  return (
    repoName: repoNames.first,
    repoNames: repoNames.toList(),
    repoPath: dir.path,
    currentBranch: _getCurrentBranch(dir.path, runner),
    branches: branches,
    worktrees: worktrees,
  );
}

Set<String>? _extractRepoNames(String rawOutput) {
  final repoNames = <String>{};
  for (final line in rawOutput.trim().split('\n')) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final remoteUrl = parts[1];
    if (isDartSdkRemote(remoteUrl)) return null;
    final name = normalizeRepoName(remoteUrl);
    if (name == null) continue;
    if (isDartSdkRepositoryName(name)) return null;
    repoNames.add(name);
  }
  return repoNames.isEmpty ? null : repoNames;
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
    '--format=%(refname:short)\t%(objectname)\t%(upstream:short)\t%(upstream:track)',
    'refs/heads/',
  ], workingDirectory: repoPath);
  if (branchResult.exitCode != 0) return const [];

  final branches = <LocalBranchEntry>[];
  for (final line in (branchResult.stdout as String).trim().split('\n')) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length >= 2) {
      branches.add((
        name: parts[0],
        sha: parts[1],
        upstream: parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null,
        upstreamTrack: parts.length > 3 ? parts[3] : '',
      ));
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
    if (currentWtPath != null) {
      worktrees.add((
        path: currentWtPath!,
        branch: currentBranch ?? '',
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
    } else if (line == 'detached') {
      currentBranch = 'DETACHED';
    } else if (line.isEmpty) {
      flush();
    }
  }
  flush();
  return worktrees;
}
