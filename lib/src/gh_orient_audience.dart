/// Owner-vs-visitor audience signal for `kscripts gh-orient`.
///
/// The signal answers one question for a draft issue or pull request: does the
/// likely reader already know the code the draft discusses? Owners skip
/// background; visitors need one orienting line and a permalink. When unsure,
/// the heuristic answers `visitor`, because an extra orienting line costs less
/// than a confused triager.
library;

/// A repository whose recent merged PRs come from this many distinct humans or
/// fewer is treated as owner-triaged.
const ownerRepoMaxDistinctAuthors = 3;

/// A mid-sized repository still counts as owner-triaged when one author
/// dominates the referenced paths.
const dominantAuthorRepoMaxDistinctAuthors = 6;

/// Minimum share of recent commits on the referenced paths for one author to
/// count as dominant.
const dominantAuthorMinShare = 0.5;

/// Whether the likely reader already knows the code under discussion.
class AudienceSignal {
  /// `owner` or `visitor`.
  final String mode;

  /// Distinct non-bot authors across the sampled merged PRs.
  final int distinctPrAuthors;

  /// Top authors on the referenced paths, most commits first, as `name (n)`.
  final List<String> topPathAuthors;

  /// Share of recent path commits held by the top author, or `null` when no
  /// paths were given.
  final double? topPathShare;

  /// One-sentence justification rendered next to [mode].
  final String evidence;

  new({
    required this.mode,
    required this.distinctPrAuthors,
    this.topPathAuthors = const [],
    this.topPathShare,
    required this.evidence,
  });

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'distinctPrAuthors': distinctPrAuthors,
    'topPathAuthors': topPathAuthors,
    if (topPathShare != null) 'topPathShare': topPathShare,
    'evidence': evidence,
  };

  String toMarkdown() => '- **Audience**: $mode ($evidence)';
}

/// Counts non-empty author names, one per line of `git log --format=%aN` or
/// `gh api .../commits` output.
Map<String, int> countAuthors(Iterable<String> lines) {
  final counts = <String, int>{};
  for (final line in lines) {
    final name = line.trim();
    if (name.isEmpty || name == 'null') continue;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return counts;
}

/// Derives the audience signal from merged-PR authorship and, when
/// [pathAuthorCounts] is non-empty, recent commit authorship on the referenced
/// paths. Many distinct path authors veto the small-repository signal, which a
/// burst of bot-authored PRs can otherwise fake.
AudienceSignal deriveAudience({
  required int distinctPrAuthors,
  Map<String, int> pathAuthorCounts = const {},
}) {
  final sorted = pathAuthorCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final total = pathAuthorCounts.values.fold<int>(0, (a, b) => a + b);
  final topShare = total == 0 ? null : sorted.first.value / total;
  final topAuthors = sorted
      .take(3)
      .map((e) => '${e.key} (${e.value})')
      .toList();
  final distinctPathAuthors = pathAuthorCounts.length;

  final manyPathAuthors = distinctPathAuthors > ownerRepoMaxDistinctAuthors;
  final smallRepo =
      distinctPrAuthors <= ownerRepoMaxDistinctAuthors && !manyPathAuthors;
  final dominant =
      topShare != null &&
      topShare >= dominantAuthorMinShare &&
      distinctPrAuthors <= dominantAuthorRepoMaxDistinctAuthors;

  final prSummary =
      '$distinctPrAuthors distinct merged-PR author'
      '${distinctPrAuthors == 1 ? '' : 's'} in sample';
  final pathSummary = topShare == null
      ? ''
      : '; paths: $distinctPathAuthors author'
            '${distinctPathAuthors == 1 ? '' : 's'}, top '
            '${sorted.first.key} ${(topShare * 100).round()}%';

  final String mode;
  final String why;
  if (smallRepo) {
    mode = 'owner';
    why = 'owner-triaged repository';
  } else if (dominant) {
    mode = 'owner';
    why = 'one author dominates the referenced paths';
  } else {
    mode = 'visitor';
    why = 'rotating or distributed triage';
  }

  return AudienceSignal(
    mode: mode,
    distinctPrAuthors: distinctPrAuthors,
    topPathAuthors: topAuthors,
    topPathShare: topShare,
    evidence: '$why: $prSummary$pathSummary',
  );
}
