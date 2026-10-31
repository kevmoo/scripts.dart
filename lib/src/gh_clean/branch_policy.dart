import '../local_repo_scanner.dart';
import '../process_utils.dart';

const _trunkCandidates = ['main', 'master', 'trunk', 'dev'];

/// Resolves the default/trunk branch name for [localRepo].
String resolveTrunkBranch(LocalRepoInfo localRepo, {String? preferredTrunk}) {
  if (preferredTrunk != null && isProtectedBranch(preferredTrunk)) {
    return preferredTrunk;
  }
  for (final candidate in _trunkCandidates) {
    if (localRepo.branches.any((b) => b.name == candidate)) {
      return candidate;
    }
  }
  return 'main';
}

/// Whether [branch] is a well-known trunk or release branch name.
bool isTrunkBranchName(String branch) {
  final lower = branch.toLowerCase().trim();
  const trunkNames = {
    'main',
    'master',
    'trunk',
    'dev',
    'beta',
    'stable',
    'release',
    'head',
  };
  return trunkNames.contains(lower);
}

bool isProtectedBranch(String branch) {
  final lower = branch.toLowerCase().trim();
  if (lower.startsWith('release/') || lower.startsWith('release-')) {
    return true;
  }
  return isTrunkBranchName(lower);
}

/// Whether [refName] is an archive or safe-kept ref marked `DO-NOT-DELETE`
/// or `DO_NOT_DELETE`.
bool isDoNotDeleteRef(String refName) {
  final upper = refName.toUpperCase();
  return upper.contains('DO-NOT-DELETE') || upper.contains('DO_NOT_DELETE');
}

/// Collects commit OIDs referenced by any local branch, local tag, or
/// [remoteRefs] entry marked `DO-NOT-DELETE` / `DO_NOT_DELETE`.
Set<String> collectDoNotDeleteOids(
  LocalRepoInfo localRepo,
  SyncProcessRunner runner, {
  Iterable<({String name, String oid})> remoteRefs = const [],
}) {
  final oids = <String>{
    for (final b in localRepo.branches)
      if (isDoNotDeleteRef(b.name) && b.sha.isNotEmpty) b.sha,
    for (final r in remoteRefs)
      if (isDoNotDeleteRef(r.name) && r.oid.isNotEmpty) r.oid,
  };
  _addDoNotDeleteTagOids(localRepo.repoPath, runner, oids);
  return oids;
}

void _addDoNotDeleteTagOids(
  String repoPath,
  SyncProcessRunner runner,
  Set<String> oids,
) {
  final res = runner('git', [
    '-C',
    repoPath,
    'for-each-ref',
    '--format=%(refname:short)\t%(objectname)\t%(*objectname)',
    'refs/tags/',
  ]);
  if (res.exitCode != 0) return;
  for (final line in (res.stdout as String).trim().split('\n')) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < 2 || !isDoNotDeleteRef(parts[0])) continue;
    final peeled = parts.length > 2 ? parts[2].trim() : '';
    final oid = peeled.isNotEmpty ? peeled : parts[1].trim();
    if (oid.isNotEmpty) oids.add(oid);
  }
}
