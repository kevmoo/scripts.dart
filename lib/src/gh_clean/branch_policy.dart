import '../local_repo_scanner.dart';

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
