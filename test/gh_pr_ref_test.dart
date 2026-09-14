import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/gh_clean.dart';
import 'package:kevmoo_scripts/src/gh_view.dart';
import 'package:kevmoo_scripts/src/local_repo_scanner.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('GhPrRef', () {
    test('parseCoreFields extracts shared identity fields', () {
      final node = {
        'number': 42,
        'title': 'feat: unify PR models',
        'url': 'https://github.com/kevmoo/scripts.dart/pull/42',
        'headRefName': 'unify-pr-ref',
        'headRefOid': 'abc1234',
        'baseRefName': 'main',
        'repository': {
          'nameWithOwner': 'kevmoo/scripts.dart',
          'url': 'https://github.com/kevmoo/scripts.dart',
        },
      };

      final core = GhPrRef.parseCoreFields(node);
      check(core).isNotNull();
      check(core!.number).equals(42);
      check(core.title).equals('feat: unify PR models');
      check(core.url).equals('https://github.com/kevmoo/scripts.dart/pull/42');
      check(core.repository).equals('kevmoo/scripts.dart');
      check(core.repoUrl).equals('https://github.com/kevmoo/scripts.dart');
      check(core.headRefName).equals('unify-pr-ref');
      check(core.headRefOid).equals('abc1234');
      check(core.baseRefName).equals('main');
    });

    test('parseCoreFields returns null when required fields are missing', () {
      check(GhPrRef.parseCoreFields({'number': 42})).isNull();
      check(
        GhPrRef.parseCoreFields({
          'number': 42,
          'title': 'test',
          'url': 'https://example.com',
          'repository': {'nameWithOwner': ''},
        }),
      ).isNull();
    });

    test(
      'GhPr and LandedPr share GhPrRef properties and worktree matching',
      () {
        final openPr = GhPr(
          number: 101,
          title: 'Open PR',
          url: 'https://github.com/kevmoo/scripts.dart/pull/101',
          isDraft: false,
          state: 'OPEN',
          reviewDecision: ReviewDecision.none,
          requestedReviewers: const [],
          totalReviewThreads: 0,
          unresolvedReviewThreads: 0,
          mergeable: MergeableState.mergeable,
          mergeStateStatus: MergeStateStatus.clean,
          isInMergeQueue: false,
          headRefName: 'feature-worktree',
          headRefOid: '1112223',
          baseRefName: 'main',
          repository: 'kevmoo/scripts.dart',
          repoUrl: 'https://github.com/kevmoo/scripts.dart',
          isRepoArchived: false,
          ciStatus: CiStatus.success,
          updatedAt: DateTime.utc(2026, 9, 14),
        );

        const landedPr = LandedPr(
          number: 102,
          title: 'Landed PR',
          url: 'https://github.com/kevmoo/scripts.dart/pull/102',
          repository: 'kevmoo/scripts.dart',
          repoUrl: 'https://github.com/kevmoo/scripts.dart',
          headRefName: 'feature-worktree',
          headRefOid: '4445556',
          baseRefName: 'main',
        );

        for (final pr in <GhPrRef>[openPr, landedPr]) {
          check(pr.repoShortName).equals('scripts.dart');
          check(pr.markdownLink).equals(
            '[#${pr.number}]'
            '(https://github.com/kevmoo/scripts.dart/pull/${pr.number})',
          );
          check(pr.markdownRepoLink).equals(
            '[kevmoo/scripts.dart](https://github.com/kevmoo/scripts.dart)',
          );
        }

        // Verify sibling folder naming match works for both GhPr and LandedPr
        final localRepo = (
          repoName: 'kevmoo/scripts.dart',
          repoNames: ['kevmoo/scripts.dart'],
          repoPath: '/workspace/scripts.dart',
          currentBranch: 'main',
          branches: <LocalBranchEntry>[],
          worktrees: [
            (
              path: '/workspace/_scripts.dart-feature-worktree',
              branch: 'DETACHED',
              sha: '1112223',
            ),
          ],
        );

        final openLoc = findLocalBranchLocation([localRepo], openPr);
        check(openLoc).isNotNull();
        check(openLoc!.repoPath)
            .equals('/workspace/_scripts.dart-feature-worktree');
        check(openLoc.isWorktree).isTrue();

        final landedWt = findMatchingWorktreeForPr(localRepo, landedPr);
        check(landedWt).isNotNull();
        check(landedWt!.path)
            .equals('/workspace/_scripts.dart-feature-worktree');
      },
    );
  });
}
