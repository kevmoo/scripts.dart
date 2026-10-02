---
name: pr-triage
description: >-
  Triages open GitHub pull request comments, review threads, merge conflicts,
  and CI workflow failures, empirically verifying reviewer claims before
  proposing a structured action plan. Use when asked to triage or address PR
  comments, review feedback, merge conflicts, or failing CI checks on a GitHub
  pull request, or when invoked via /pr-triage. Don't use for multi-repo PR
  cleanup sweeps (use pr-cleanup) or initial adversarial code review (use
  pr-review).
---

# GitHub PR Triage (`/pr-triage`)

## Quick Start

```bash
# Triage the active PR for a target repository checkout or worktree:
kscripts pr-triage --dir /path/to/target-repository [--pr 123]

# Reply to a comment and resolve a review thread:
kscripts pr-triage resolve --dir /path/to/target-repository <thread_id> [<comment_id> "<reply_body>"]

# Post an optional top-level reply, optionally dismiss a stale CHANGES_REQUESTED review, and re-request review:
kscripts pr-triage re-request --dir /path/to/target-repository <reviewer_login> [--comment "<reply_body>"] [--dismiss <review_database_id> -m "<reason>"]
```

## When to use this skill

- Use when asked to address review comments, pull request feedback, merge
  conflicts, or failing CI/CD runs on a GitHub pull request in an interactive,
  single-pass manner (`"look at comments on my PR"`, `"address reviews"`,
  `"fix the build/checks"`).

## 🧠 Critical Mindset: Reviewer Feedback is NOT Gospel

- **Reviewers make mistakes**: Do NOT assume any reviewer — whether an AI bot
  (Gemini Code Assist, Copilot) or a human engineer — is infallible.
- **Treat Severity Badges as Unverified External Claims**: Bot tags
  (`![critical]`, `![security-high]`) are unverified external claims, NOT
  compiler diagnostics.
- **Mandatory Pre-Edit Empirical Verification Gate**: Before editing code for
  any comment claiming a syntax error, compilation failure, or type issue, run
  `dart analyze` on the **unmodified existing codebase** first. If
  `dart analyze` returns **0 issues**, classify the item as
  `👎 Disagree (Hallucinated Syntax/Compile Error)` and make NO code changes.
- **You are free to disagree**: Always test claims empirically (`dart analyze`,
  `dart test`). If a suggestion introduces regressions or the current code is
  already optimal, mark it `👎 Disagree` with technical rationale.

## How to use this skill (The Workflow)

- **NEVER GUESS Target PR or Branch**: If the target PR/branch is not provided
  and the workspace is on `main`/`master`, detached `HEAD`, or matches multiple
  open PRs, **STOP** and ask the user via `ask_question` or chat.

1. **Run `kscripts pr-triage`**:

   ```bash
   kscripts pr-triage --dir <path-to-target-repository> [--pr <pr-number-or-url>]
   ```

   **Save the exact, untruncated stdout** as `raw_triage_output.md` in the
   conversation artifact directory (preserving the `Reviewer Dropped from Queue`
   banner and all review/thread IDs).

2. **Verify Workspace & Mergeable State**:
   - Confirm local branch matches `headRefName`. If `Sync Status` is
     `behind_remote`, run `git pull`; if `ahead_of_remote` or `diverged`, sync
     before editing code.
   - If `Mergeable` is `CONFLICTING` (`DIRTY`), treat merge conflicts as a
     `🔥 Urgent` blocker in `pr_triage_report.md` and resolve via a forward
     merge commit
     (`git fetch origin <baseRefName> && git merge origin/<baseRefName>`), never
     `git rebase`. When committing a monorepo merge with
     `git commit --no-verify` (to avoid reformatting unrelated upstream files),
     explicitly run `dart format` on only the PR's touched `.dart` files before
     committing or pushing.

3. **Analyze Open Comments**:
   - Inspect unresolved review threads, top-level reviews, and general PR
     comments. Ignore resolved threads and self-authored comments unless they
     provide context.

4. **Analyze CI Status & Failures**:
   - **Active/Pending CI Hard Block**: If any CI status checks are currently
     running or pending, call `ask_question`:
     - Option 1: `(Recommended) Proceed with triaging open comments now`
     - Option 2: `Wait for active CI status checks to complete first`
       **MANDATORY HARD BLOCK**: Halt execution after calling `ask_question`. Do
       NOT proceed to Step 5 or create `pr_triage_report.md` until the user
       responds.
   - **`ACTION_REQUIRED` Checks**: Distinguish `ACTION_REQUIRED` checks from
     test failures. Because pushing a commit resets `ACTION_REQUIRED` checks,
     only trigger/approve them after all code commits are pushed (or when no
     code changes are needed).

5. **Generate a Triage Report (`pr_triage_report.md`) & Log Review Escapes**:
   - Create `pr_triage_report.md` (`RequestFeedback: false`, `UserFacing: true`
     in `ArtifactMetadata`) following the artifact skeleton in
     [`references/graphql_and_templates.md`](references/graphql_and_templates.md).
   - Link to `raw_triage_output.md` at the top and group related comments/CI
     failures into cohesive action items containing:
     - **Summary & Link**: Descriptive link with number and
       `@reviewer_username`.
     - **Identifiers**: Preserve `Thread ID` (`PRRT_...`), `Comment ID`, or
       `Review ID` (`PRR_...`) + numeric `Database ID`.
     - **Agent Assessment**: Agreement Level (`🔥 Urgent [Valid — Fix]`,
       `👍 Solid [Valid — Fix]`, `🤷 Meh`, or `👎 Disagree`), Empirical
       Verification output, and Rationale.
     - **Planned Action & 2-Bucket TDD Filter**: Target file/line changes plus
       either a **Companion Test** (`test/..._test.dart` for bug fixes, edge
       cases, or behavior changes) or **Explicit Skip (`None — <reason>`)** for
       copy/comment/rename or behavior-preserving refactors.
   - **Wire `[Valid — Fix]` Findings to `/sharpen-later` (`--cat=review-escape`,
     `FU4`)**: Whenever a reviewer comment or thread is classified as
     `[Valid — Fix]` (a real bug, missing edge case, API leak, or convention
     violation that escaped local pre-review) and `/sharpen-later` is available,
     record it with `--cat=review-escape` and
     `--agent-note "<owner>/<repo>#<PR>: <why local pre-review missed it>"`.

6. **Interactive Approval Gate (`ask_question`)**:
   - Immediately after writing `pr_triage_report.md`, call `ask_question` to
     gate implementation (see
     [`references/graphql_and_templates.md`](references/graphql_and_templates.md)):
     - Option 1: `(Recommended) Implement the proposed fixes and test plan`
     - Option 2: `Adjust the triage plan first`
     - Option 3: `Do not edit files (keep triage report only)`
   - DO NOT edit repository files until the user approves via `ask_question`.

7. **Surgical Implementation & Verification (Red-Green TDD)**:
   - **Test First (Red) -> Implementation (Green)**: Write approved companion
     tests in `test/` first and verify failure on unpatched code, then apply the
     fix and run `dart format` (explicitly targeting touched `.dart` files when
     hooks or `--no-verify` are used), `dart analyze`, and `dart test`.
   - **Sync PR Title & Description**: If public APIs or architecture changed,
     update via `cat << 'EOF' | gh pr edit <pr> --title "..." --body-file -`.
   - **Live Read-Only Smoke Check**: Auto-run side-effect-free CLI paths
     (`--help`, `--dry-run`, `status`/`list`/`view`) when `<= 15s` and `~0`
     risk; offer in Step 8 when `> 15s`.

8. **Verify Git State and Offer Unified Resolution Menu**:
   - Run `git status -s --untracked=no` and present the unified `ask_question`
     completion menu from
     [`references/graphql_and_templates.md`](references/graphql_and_templates.md)
     (including `"dismiss stale CHANGES_REQUESTED review"` whenever an open
     `CHANGES_REQUESTED` review was fully addressed).

## Replying, Resolving Threads, and Re-Requesting Review

See [`references/graphql_and_templates.md`](references/graphql_and_templates.md)
for full `kscripts pr-triage resolve` / `re-request` syntax, GitHub
state-machine notes, and underlying GraphQL/REST schemas.

- **Never Re-Request an Active `APPROVED` Reviewer**: `--add-reviewer` revokes
  active approvals. Run `kscripts pr-triage re-request` **ONLY when ALL 3
  hold**:
  1. The human reviewer is **not** currently listed in `reviewRequests`, **AND**
  2. Their latest state in `latestReviews` is **NOT** `"APPROVED"` (`COMMENTED`,
     `CHANGES_REQUESTED`, or `DISMISSED`), **AND**
  3. Commits were pushed or replies posted addressing their feedback.
- **Re-Request After `dismiss_stale_reviews` Auto-Dismisses an Approval**: In
  repositories with `dismiss_stale_reviews` enabled (such as `flutter/flutter`),
  pushing new commits automatically transitions a prior `"APPROVED"` review to
  `"DISMISSED"` and removes the reviewer from `reviewRequests`. Always check
  `gh pr view <pr_number> -R <owner/repo> --json reviewDecision,latestReviews,reviewRequests`
  after `git push` and re-request any reviewer whose approval was dismissed via
  `kscripts pr-triage re-request --dir <repo-path> <reviewer_login>`.
- **Stop When Already Queued**: If `<login>` is already in `reviewRequests` and
  all feedback is addressed on the latest commit, **STOP**.

## Constraints

- **Hard CI Gate**: Never generate `pr_triage_report.md` while CI is pending
  without first halting on Step 4's `ask_question`.
- **Pre-Edit Approval Gate**: Never modify repository files before user approval
  of `pr_triage_report.md`.
- **Single-Gate VCS Execution**: Selecting a commit/push option in Step 8's
  `ask_question` authorizes committing and pushing without a second prompt.
- **Sync Code Before Comments**: Never post "Fixed" replies or resolve threads
  while code fixes remain uncommitted or unpushed.
- **Prohibitions**: Never run `git commit --amend` or `git push --force` /
  `--force-with-lease`. Always use `kscripts pr-triage` over manual API calls.
