/// Detected machine persona and environment configuration for `/relay`.
final class RelayEnvironment {
  final String moniker;
  final String slug;
  final String matchPattern;
  final String hostShort;
  final String archTag;
  final String defaultTo;
  final String nowPt;
  final String nowUtc;
  final String sessionShort;
  final String workspace;
  final String publicGithubRepo;
  final String corpRepo;
  final String corpDir;
  final String ossRepo;
  final String ossDir;
  final bool hasGgh;
  final bool hasGh;

  const new({
    required this.moniker,
    required this.slug,
    required this.matchPattern,
    required this.hostShort,
    required this.archTag,
    required this.defaultTo,
    required this.nowPt,
    required this.nowUtc,
    required this.sessionShort,
    required this.workspace,
    required this.publicGithubRepo,
    required this.corpRepo,
    required this.corpDir,
    required this.ossRepo,
    required this.ossDir,
    required this.hasGgh,
    required this.hasGh,
  });

  /// Formats the Markdown envelope header block.
  String formatHeader({
    required String toTarget,
    required String threadLabel,
    required String stateTag,
    required String channelResolved,
    required String classification,
    String? repoOverride,
    String? modelOverride,
  }) {
    final modelSegment =
        (modelOverride != null && modelOverride.trim().isNotEmpty)
        ? ' · **Model**: `${modelOverride.trim()}`'
        : '';
    if (channelResolved == 'oss') {
      final repoTag = _firstNonEmpty([repoOverride, publicGithubRepo, ossRepo]);
      return '### $moniker (`$hostShort` · `$archTag`) → $toTarget\n'
          '> **Thread**: `$threadLabel` | **State**: `$stateTag` | '
          '**Time**: `$nowPt`\n'
          '> **Repo**: `$repoTag`$modelSegment · '
          '**Session**: `$sessionShort` · '
          '**Classification**: `$classification`';
    }
    final wsTag = _firstNonEmpty([repoOverride, workspace]);
    return '### $moniker (`$hostShort` · `$archTag`) → $toTarget\n'
        '> **Thread**: `$threadLabel` | **State**: `$stateTag` | '
        '**Time**: `$nowPt`\n'
        '> **Workspace**: `$wsTag`$modelSegment · '
        '**Session**: `$sessionShort` · '
        '**Classification**: `$classification`';
  }
}

String _firstNonEmpty(List<String?> candidates) {
  for (final c in candidates) {
    if (c != null && c.trim().isNotEmpty) return c.trim();
  }
  return '';
}
