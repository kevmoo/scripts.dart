---
name: pr-cleanup
description: >-
  Orchestrates multi-repo GitHub pull request, Gerrit CL, local Git worktree,
  and branch cleanup sweeps alongside active open-PR next-step triage. Use when
  asked to run a PR cleanup sweep, prune merged worktrees or branches, review
  open PRs and next steps across repositories, or reconcile local checkouts in
  ~/github against GitHub, Gerrit, and active agent sessions. Don't use for
  triaging inline review comments or CI failures on a single PR (use pr-triage)
  or creating new worktrees (use new-worktree).
compatibility: "Requires kscripts (kevmoo_scripts via dart install) and local checkouts in ~/github"
metadata:
  author: kevmoo
  target_environment: personal
---

# PR & Worktree Cleanup Sweep (`pr-cleanup`)

> [!NOTE]
>
> This skill targets the personal repository layout (`~/github` and
> `~/github/kevmoo/*`) and invokes the unified `kscripts` AOT CLI.

## Quick Start & Prerequisites

Ensure `kscripts` is installed and up to date on `PATH`. If `kscripts` is
missing, install it from the canonical Git remote:

```bash
dart install 'kevmoo_scripts@{git: https://github.com/kevmoo/scripts.dart}'
```

Thereafter `upkeep update dart_install` keeps it current -- it re-reads the
source descriptor from the installed bundle's own `pubspec.lock` and reinstalls
from the same remote.

> [!WARNING]
>
> Do **not** run `dart install ~/github/kevmoo/scripts.dart`. Installing from a
> local path builds whatever branch that checkout is on, and it _replaces_ the
> `app-bundles/kevmoo_scripts/git/<sha>/` bundle with a `local/` one -- which
> permanently repoints `upkeep update dart_install` at that checkout instead of
> the remote. Only use a path install to test uncommitted work, and reinstall
> from Git afterwards.

## 1. Read-Only Pre-Flight Sweep (Always Start Read-Only)

Never pass `--apply` on the initial scan. Run the unified parallel collector (or
the individual subcommands when targeting a single slice) to build a complete
view of `~/github` and `~/github/dart-sdk`:

1. **Unified Multi-Repo GitHub & Gerrit Sweep (Recommended)**:
   ```bash
   kscripts pr-cleanup --markdown
   ```
   _(Concurrently queries landed GitHub PRs, open GitHub PRs, cross-author and
   closed-unmerged branches, unlinked local worktrees, and Dart SDK Gerrit CLs,
   rendering `✅ Ready to Prune`, `🚫 Active / Hands-Off` with
   `Opened / Touched` dates, `📌 Locked Worktrees (FYI — Safe-Kept Local Work)`,
   and `⚠️ Needs Triage`)._
2. **Targeted Individual Collectors** _(optional when scoping to a single
   view)_:
   - **Merged/Closed PRs, Stale Worktrees & Dangling Remote Branches**:
     ```bash
     kscripts gh-clean -l 50 --markdown
     ```
   - **Open Active GitHub PRs & Reviewer/CI Next Steps**:
     ```bash
     kscripts gh-view -d 14 --markdown
     ```
     _(Omit `-d 14` for all open PRs, or pass `-d <days>` to adjust the
     window)._
   - **Dart SDK Gerrit Worktrees & CL Status** _(when `~/github/dart-sdk`
     exists)_:
     ```bash
     kscripts gerrit-view -p ~/github/dart-sdk
     ```
   - **Open Assigned GitHub Issues** _(optional for backlog triage)_:
     ```bash
     kscripts gh-issues --linked-prs --markdown
     ```

### Ad-Hoc Sorting & Filtering with DuckDB (`--json`)

When the user asks for custom sorting, age calculations, or filtering (for
example, oldest open PRs by `createdAt`, stalest `updatedAt`, or specific
reviewer/CI states), pipe `--json` into `duckdb -markdown` instead of adding new
CLI flags:

```bash
# Project & sort active GitHub PRs + Gerrit CLs (active) by opened/touched date:
kscripts pr-cleanup --json | duckdb -markdown -c "
  WITH a AS (
    SELECT unnest(active, recursive := true)
    FROM read_json_auto('/dev/stdin')
  )
  SELECT
    '[' || CASE WHEN source='github' THEN '#' ELSE 'CL ' END || number || '](' || url || ')' AS Target,
    repository AS Repo,
    left(title, 42) AS Title,
    ciBadge AS CI,
    reviewBadge AS Review,
    strftime(createdAt::TIMESTAMPTZ, '%Y-%m-%d') AS Opened,
    strftime(updatedAt::TIMESTAMPTZ, '%Y-%m-%d') AS Touched,
    date_diff('day', createdAt::TIMESTAMPTZ, now()) AS AgeDays
  FROM a
  ORDER BY createdAt ASC;
"

# Project & filter rich open GitHub PR telemetry from gh-view --json:
kscripts gh-view --json | duckdb -markdown -c "
  WITH prs AS (
    SELECT unnest(items, recursive := true)
    FROM read_json_auto('/dev/stdin')
  )
  SELECT
    '[#' || number || '](' || url || ')' AS PR,
    repository AS Repo,
    category AS Bucket,
    ciStatus AS CI,
    strftime(createdAt::TIMESTAMPTZ, '%Y-%m-%d') AS Opened,
    touched AS Touched
  FROM prs
  WHERE NOT isDraft
  ORDER BY updatedAt ASC;
"
```

## 2. Active Worktree & Session Ownership Cross-Reference

Before proposing to delete any worktree, local branch, or unpushed commit:

1. **Inspect Dirty / Unpushed Worktrees**:
   - For any worktree flagged by `kscripts gh-clean` as having uncommitted
     changes or unpushed commits, run:
     ```bash
     git -C <worktree_path> status -s
     git -C <worktree_path> log -n 2 --oneline
     ```
   - **Squash-Merge Ancestry Check**: If a merged PR branch still reports
     unpushed commits past PR HEAD, fetch `origin/main` first and check whether
     the branch is an ancestor of `origin/main`:
     ```bash
     git -C <repo_path> fetch origin main --quiet
     git -C <repo_path> rev-list --count origin/main..<branch>
     ```
     If the count is `0`, the branch was reset onto the squash-merge commit and
     is safe to delete via `git -C <repo_path> branch -D <branch>`.
2. **Cross-Reference Active Sessions & Local Tasks**:
   - Check whether any worktree is in use by another terminal or agent session.
   - If an owning session is **actively thinking/running** (or the PR/CL is
     open), keep the worktree in **`🚫 Active / Hands-Off`** and **warn the
     user** rather than interrupting an in-flight turn.
   - If a worktree belongs to a **waiting/idle** session whose PR/CL has already
     **merged**, include pruning its VCS state in **`✅ Ready to Prune`** and
     reconcile any linked local tasks or waiting sessions according to your
     workspace rules.

## 3. Classification & Report

Present the findings in a structured Markdown report (or artifact for large
sweeps) organized into four descriptive categories:

- **`✅ Ready to Prune` (JSON field: `readyToPrune` — Merged PRs/CLs & Clean
  Worktrees)**:
  - Clean unlocked worktrees (`git worktree remove`), merged local feature
    branches (`git branch -D`), dangling remote head branches on writable repos,
    and trunk fast-forwards (`--ff-only`).
  - List any linked tasks or waiting sessions whose PRs have landed so they can
    be reconciled after VCS cleanup.
- **`🚫 Active / Hands-Off` (JSON field: `active` — Open PRs, Active Gerrit CLs,
  In-Flight Worktrees)**:
  - List open PRs from `kscripts gh-view` and active Gerrit CLs from
    `kscripts gerrit-view` with their CI status, reviewer state (`⏳ Awaiting`
    vs `🔔 Ping Reviewer` vs `🔄 Re-request Review` vs `❌ Action Needed`), and
    local worktree mapping (active open/draft PR worktrees remain here even when
    they have local unpushed commits).
  - When `kscripts gh-view` flags `🔄 **Re-request Review** (@reviewer)`, that
    human reviewer previously submitted a review (`COMMENTED`,
    `CHANGES_REQUESTED`, or `DISMISSED`) and was dropped from GitHub's
    `reviewRequests`. Even if an `@reviewer PTAL` comment was posted, the PR is
    not in their GitHub Review Queue (`review-requested:@me`) until re-requested
    via `gh pr edit <PR> -R <owner/repo> --add-reviewer <login>`.
  - **Three-State `CHANGES_REQUESTED` Disambiguation (Zero Extra `gh` Calls)**:
    1. `🔴 **Changes Requested** (@reviewer)`: Author has **not** yet pushed a
       fix or replied since the review (`⚠️ Action Needed` — author's ball).
    2. `🔄 **Re-request Review** (@reviewer)`: Author pushed a fix or replied
       after the review and resolved threads, but `@reviewer` was dropped from
       `reviewRequests` (`⚠️ Action Needed` — run `--add-reviewer <login>`).
    3. `🟡 **Re-review Requested** (@reviewer)`: `@reviewer` is **already in
       `reviewRequests`** (`🟡 In Review Queue` — reviewer's ball). Even though
       GitHub's raw `reviewDecision` remains `CHANGES_REQUESTED`, do **not**
       re-run `--add-reviewer` or run `pr-triage`. Only if another maintainer
       has already `APPROVED` (`🟢 Approved (@approver)`) and the prior
       `CHANGES_REQUESTED` review is a stale veto on an older commit, surface
       the option (gated via `ask_question`) to dismiss the stale review.
- **`📌 Locked Worktrees (FYI — Safe-Kept Local Work)` (JSON field:
  `lockedWorktrees`)**:
  - Local worktrees locked via
    `git worktree lock --reason "<descriptive reason>"` are omitted from
    `⚠️ Needs Triage` (and skipped by `gh-clean` pruning) and surfaced in the
    report as an FYI table (including `Lock Reason`, `Commits Ahead`, and
    `Last Touched` date) so the human can periodically review safe-kept local
    prototypes and decide if any should be unlocked
    (`git worktree unlock <worktree_path>`) and pruned.
- **`⚠️ Needs Triage` (JSON field: `needsTriage` — Unlocked Unlinked Worktrees,
  Closed-Unmerged PRs, Dirty Worktrees)**:
  - Detail the exact modified/untracked files (`git status -s`) or unmerged
    commits so the user can decide how to handle each item.
  - Dangling unlinked worktrees must always be triaged carefully—never bulk
    force-removed. Recommend triaging each dangling worktree to **either
    delete** (`git -C <parent_repo> worktree remove --force <worktree_path>` and
    `git -C <parent_repo> branch -D <branch>`) **OR lock for safekeeping**
    (`git -C <parent_repo> worktree lock --reason "<descriptive reason with project, context, and why kept>" <worktree_path>`).
  - Explicitly encourage the human to provide a descriptive `--reason` that
    includes project context, ticket/goal, and why the worktree is being kept.

## 4. Approval Gate & Execution

Gate execution via `ask_question` with explicit category choices:

- `(Recommended) Execute Ready-to-Prune cleanup only (prune merged PRs, clean worktrees & remote branches)`
- `Triage Needs-Triage worktrees (lock with descriptive --reason for safekeeping or delete individually)`
- `Stop here (keep read-only report only)`

Once approved:

1. **Execute `✅ Ready to Prune` Cleanup**:
   - If **any** merged-PR worktree was held back in **`🚫 Active / Hands-Off`**
     (because an active session is still using it), run
     `kscripts gh-clean -R <owner/repo> --apply` for each approved
     `✅ Ready to Prune` repository individually so the active worktree is not
     touched.
   - Only run unscoped `kscripts gh-clean -l 50 --apply` (or
     `kscripts pr-cleanup --apply`) when **zero** merged-PR worktrees were
     reclassified into `🚫 Active / Hands-Off`.
2. **Triage `⚠️ Needs Triage` Worktrees Individually** _(never bulk
   force-remove)_:
   - For each worktree the user chooses to **lock for safekeeping**, run:
     ```bash
     git -C <parent_repo> worktree lock --reason "<descriptive reason with project, context, and why kept>" <worktree_path>
     ```
   - For each worktree the user explicitly confirms to **delete**, run:
     ```bash
     git -C <parent_repo> worktree remove --force <worktree_path>
     git -C <parent_repo> branch -D <branch>
     ```
3. **Reconcile Linked Tasks & Waiting Sessions**:
   - After pruning landed PRs/CLs, verify and close any linked local tasks or
     notify waiting/idle sessions per your workspace rules (warning the user
     first if an owning session is actively thinking/running).
