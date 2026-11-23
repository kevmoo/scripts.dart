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

# Reply to an inline comment WITHOUT resolving its thread (clarification or open discussion):
kscripts pr-triage reply --dir /path/to/target-repository [--pr 123] [--react <+1|-1>] <comment_id> "<reply_body>"

# Reply to a comment, optionally react (+1/-1 for @gemini-code-assist), and resolve a review thread:
kscripts pr-triage resolve --dir /path/to/target-repository [--pr 123] [--react <+1|-1>] <thread_id> [<comment_id> ["<reply_body>"]]

# Post a standalone +1/-1 reaction (unresolved thread or --issue-comment conversation reply):
kscripts pr-triage react --dir /path/to/target-repository [--pr 123] [--issue-comment] <comment_id> <+1|-1>

# Post an optional top-level reply, optionally dismiss a stale CHANGES_REQUESTED review, and re-request review:
kscripts pr-triage re-request --dir /path/to/target-repository [--pr 123] <reviewer_login> [--comment "<reply_body>"] [--dismiss <review_database_id> -m "<reason>"]
```

## When to use this skill

- Use for single-pass interactive triage of review comments, merge conflicts, or
  failing CI checks on a GitHub PR (`"look at comments on my PR"`,
  `"address reviews"`, `"fix the build/checks"`).

## 🧠 Critical Mindset: Reviewer Feedback is NOT Gospel

- **Reviewers and severity badges are unverified claims**: Neither AI bots
  (Gemini Code Assist, Copilot) nor human engineers are infallible, and bot tags
  (`![critical]`, `![security-high]`) are NOT compiler diagnostics.
- **Mandatory Pre-Edit Empirical Verification Gate**: Before editing code for
  any claimed syntax, compile, or type error, run `dart analyze` on the
  **unmodified codebase** first; if it reports **0 issues**, mark the item
  `👎 Disagree (Hallucinated Syntax/Compile Error)` with NO code changes.
- **You are free to disagree**: Verify claims with `dart analyze` and
  `dart test`; if a suggestion regresses behavior or current code is already
  optimal, mark it `👎 Disagree` with technical rationale.
- **Rank on Code Quality, Never CI or Approval Inertia**: Score Agreement Levels
  and Step 6's `(Recommended)` option strictly on code correctness, API and
  idiom cleanliness, and repo conventions. Never downgrade a known-valid
  in-scope fix to `🤷 Meh`, defer it to a follow-up PR, or recommend keeping
  code unchanged to avoid restarting CI or `dismiss_stale_reviews` on an
  `APPROVED` vote. Recommend the clean fix and note briefly if pushing restarts
  CI or requires re-requesting a dismissed approval in Step 8.

## How to use this skill (The Workflow)

- **NEVER GUESS Target PR or Branch**: If the target PR/branch is omitted and
  the checkout is on `main`/`master`, detached `HEAD`, or matches multiple open
  PRs, **STOP** and ask the user via `ask_question` or chat.

1. **Run `kscripts pr-triage`**: Execute
   `kscripts pr-triage --dir <path-to-target-repository> [--pr <pr-number-or-url>]`
   and **save the exact, untruncated stdout** as `raw_triage_output.md` in the
   conversation artifact directory (preserving the `Reviewer Dropped from Queue`
   banner and all review/thread IDs).

2. **Verify Workspace & Mergeable State**:
   - Confirm local branch matches `headRefName`; run `git pull` if
     `behind_remote`, or sync before editing if `ahead_of_remote` or `diverged`.
   - If `Mergeable` is `CONFLICTING` (`DIRTY`), treat merge conflicts as a
     `🔥 Urgent` blocker in `pr_triage_report.md` and resolve via a forward
     merge (`git fetch origin <baseRefName> && git merge origin/<baseRefName>`,
     never `git rebase`). When committing a monorepo merge with
     `git commit --no-verify`, explicitly run `dart format` on only the PR's
     touched `.dart` files before committing or pushing.

3. **Analyze Open Comments**: Inspect unresolved review threads, top-level
   reviews, and general PR comments (ignoring resolved threads and self-authored
   comments unless they provide context).

4. **Analyze CI Status & Failures**:
   - **Active/Pending CI Hard Block**: If any CI checks are running or pending,
     call `ask_question`
     (`(Recommended) Proceed with triaging open comments now` vs.
     `Wait for active CI status checks to complete first`) and **HALT** — do NOT
     proceed to Step 5 or write `pr_triage_report.md` until answered.
   - **`ACTION_REQUIRED` Checks**: Pushing a commit resets `ACTION_REQUIRED`
     checks; only trigger/approve them after all commits are pushed (or when no
     code edits are needed).

5. **Generate a Triage Report (`pr_triage_report.md`) & Log Review Escapes**:
   - Write `pr_triage_report.md` (`RequestFeedback: false`, `UserFacing: true`
     in `ArtifactMetadata`) per
     [`references/graphql_and_templates.md`](references/graphql_and_templates.md),
     linking `raw_triage_output.md` and grouping related items with:
     - **Summary & Identifiers**: Link with `@reviewer_username`, plus
       `Thread ID` (`PRRT_...`), `Comment ID`, or `Review ID` (`PRR_...`) +
       numeric `Database ID`.
     - **Agent Assessment**: Agreement Level (`🔥 Urgent [Valid — Fix]`,
       `👍 Solid [Valid — Fix]`, `🤷 Meh`, `👎 Disagree`, or gated
       `❓ Clarify (Author)` / `❓ Clarify (Reviewer)`), Empirical Verification,
       and Rationale.
     - **Gated `❓ Clarify` Admission Rules (All 3 Preconditions Required)**:
       1. **Exhaust local checks first (`checked:` proof)**: Run `dart analyze`,
          `dart test`, caller/diff tracing, and `gh pr list --state all` first,
          recording
          `checked: <what was inspected and why it does not settle this>` in
          `Empirical Verification` (never use `❓ Clarify` for codebase facts or
          `?` comments carrying a verifiable `suggestion` block).
       2. **Material behavioral/API/scope divergence**: Require `2+` plausible
          readings that alter runtime/build behavior, public API, or PR scope
          (minor local/reversible choices stay `👍 Solid [Valid — Fix]` with a
          1-line noted default).
       3. **3-party target split**: Use `❓ Clarify (Author)` when a clear
          comment exposes a PR-author design/scope trade-off (`2–3` concrete
          options in Step 6). Use `❓ Clarify (Reviewer)` (**human reviewers
          only — never `@gemini-code-assist` or non-replying bots**) when human
          wording remains underspecified after `checked:`: set
          `Code / Doc Changes` to `Pending clarification` and draft a
          `<= 40`-word `Outbound Draft Reply` (`what was checked` + crisp
          `A vs. B?` question) via `kscripts pr-triage reply` (**keep thread
          unresolved**).
     - **Planned Action & 2-Bucket TDD Filter**: Target file/line edits, `+1`/
       `-1` reaction for actionable `@gemini-code-assist` comments, and either a
       **Companion Test** (`test/..._test.dart` for bugs/edge cases/behavior
       changes) or **Explicit Skip (`None — <reason>`)** for copy/rename,
       behavior-preserving refactors, or `Pending clarification`.
   - **Wire `[Valid — Fix]` to `/sharpen-later` (`--cat=review-escape`,
     `FU4`)**: When `/sharpen-later` is available, log real bugs, missing edge
     cases, API leaks, or convention escapes classified `[Valid — Fix]` with
     `--cat=review-escape` and
     `--agent-note "<owner>/<repo>#<PR>: <why local pre-review missed it>"`.

6. **Interactive Approval Gate (`ask_question`)**:
   - Immediately after writing `pr_triage_report.md`, call `ask_question` per
     [`references/graphql_and_templates.md`](references/graphql_and_templates.md):
     - **All items unambiguous**: Offer
       `(Recommended) Implement the proposed fixes and test plan` (or
       `(Recommended) Proceed to Step 8 replies/reactions (no code edits)`) and
       `Do not edit files (keep triage report only)`.
     - **`❓ Clarify` or genuine trade-offs present**: Offer 2 to 3 concrete
       forks ranked on code quality plus
       `Do not edit files (keep triage report only)`. Use Option A vs. Option B
       for `❓ Clarify (Author)`, or apply clear fixes + post the open `reply`
       vs. ask via `reply` before editing for `❓ Clarify (Reviewer)`. Holding
       off on speculative edits while clarifying ambiguous human-reviewer intent
       stays valid when CI is expensive, unlike skipping known-valid fixes.
   - DO NOT edit repository files or post GitHub replies before user approval.

7. **Surgical Implementation & Verification (Red-Green TDD)**:
   - **Strict Diff Scope**: Keep fixes strictly scoped to the reviewed defect
     with no unsolicited adjacent refactors; when touching AST/symbol resolution
     or visitor order, test forward-referenced and unresolved/error inputs.
   - **Whole-Diff Nit Sweep (`git diff <base>...HEAD`)**: When fixing a wording,
     style, doc-comment, or naming nit, sweep
     `git diff origin/<baseRefName>...HEAD` for sibling occurrences across the
     PR diff.
   - **Test First (Red) -> Implementation (Green)**: Verify companion tests fail
     on unpatched code first, apply the fix, and run `dart format` (explicitly
     targeting touched `.dart` files when `--no-verify` or hooks apply),
     `dart analyze`, and `dart test`.
   - **Sync PR Title & Description (Read-Modify-Write)**: When public APIs,
     architecture, behavior, or verification notes change, save
     `gh pr view <pr> --json body --jq .body > /tmp/pr_<pr>.md`, copy to
     `/tmp/pr_<pr>.orig.md`, edit only affected summary lines (leaving
     human-authored text and `.github/PULL_REQUEST_TEMPLATE.md` `[x]`/`[ ]`
     boxes untouched), verify via
     `diff -u /tmp/pr_<pr>.orig.md /tmp/pr_<pr>.md || true`, and run
     `gh pr edit <pr> --body-file /tmp/pr_<pr>.md` (adding `--title "..."` only
     when the title changes).
   - **Live Read-Only Smoke Check**: Auto-run `<= 15s`, `~0`-risk CLI checks
     (`--help`, `--dry-run`, `status`/`list`/`view`); offer in Step 8 if
     `> 15s`.

8. **Verify Git State and Offer Unified Resolution Menu**:
   - Run `git status -s --untracked=no` and present the Step 8 `ask_question`
     menu from
     [`references/graphql_and_templates.md`](references/graphql_and_templates.md)
     (including `"dismiss stale CHANGES_REQUESTED review"` whenever an open
     `CHANGES_REQUESTED` review was fully addressed).

## Replying, Resolving Threads, and Re-Requesting Review

See [`references/graphql_and_templates.md`](references/graphql_and_templates.md)
for full `kscripts pr-triage reply` / `resolve` / `react` / `re-request` syntax,
GitHub state-machine notes, and GraphQL/REST schemas.

- **Keep Clarification & Open-Discussion Threads Unresolved (`reply` vs.
  `resolve`)**: Use `kscripts pr-triage reply` for `❓ Clarify (Reviewer)`
  questions and human `👎 Disagree` replies where discussion remains open so the
  reviewer can respond and resolve the thread; use `resolve` for implemented
  fixes, answered factual questions, and `@gemini-code-assist` bot threads.
- **React `+1` / `-1` on `@gemini-code-assist` Review Comments**: Public
  GitHub's `@gemini-code-assist` (`gemini-code-assist[bot]` in REST) uses 👍
  (`+1`) and 👎 (`-1`) reactions as quality feedback. In Step 8 (never during
  read-only triage), pass `--react +1` for `[Valid — Fix]` and `--react -1`
  (with a concise factual reply) for `👎 Disagree` false positives on
  `kscripts pr-triage resolve` — or run
  `kscripts pr-triage react --dir <repo-path> [--pr <pr_number>] [--issue-comment] <comment_id> <+1|-1>`
  when leaving a thread open or reacting to a conversation reply. Skip reactions
  on neutral `🤷 Meh` items, `## Summary of Changes`, top-level `## Code Review`
  headers, and CI bots (`github-actions[bot]`).
- **Never Re-Request an Active `APPROVED` Reviewer**: `--add-reviewer` revokes
  active approvals. Run `kscripts pr-triage re-request` **ONLY when ALL 3
  hold**: (1) the human reviewer is **not** in `reviewRequests`, (2) their
  latest state in `latestReviews` is **NOT** `"APPROVED"` (`COMMENTED`,
  `CHANGES_REQUESTED`, or `DISMISSED`), and (3) commits were pushed or replies
  posted addressing their feedback.
- **Always Pass `--pr <N>` on Multi-PR Triage**: Because `reply`, `resolve`, and
  `re-request` infer the PR from the active branch when `--pr` is omitted, pass
  `--pr <N>` explicitly across multi-PR runs or off-branch checkouts.
- **Re-Request After `dismiss_stale_reviews` Auto-Dismisses an Approval**: In
  repos with `dismiss_stale_reviews` (such as `flutter/flutter`), pushing
  commits transitions a prior `"APPROVED"` review to `"DISMISSED"` and drops the
  reviewer via GitHub's async `synchronize` webhook. Run `sleep 3` after
  `git push`, check
  `gh pr view <pr_number> -R <owner/repo> --json reviewDecision,latestReviews,reviewRequests`,
  and re-request any dismissed reviewer via
  `kscripts pr-triage re-request --dir <repo-path> [--pr <pr_number>] <reviewer_login>`.
- **Stop When Already Queued**: If `<login>` is already in `reviewRequests` and
  all feedback is addressed on the latest commit, **STOP**.
- **Multi-PR Stack & Release Trunk Verification**: When landing multiple PRs
  touching `CHANGELOG.md` or shared files before a release, verify each reached
  `state == "MERGED"` (`gh pr view <N> --json state,mergeCommit`), fast-forward
  trunk (`git fetch origin && git merge --ff-only origin/<baseRefName>`), and
  run `dart test` on trunk before tagging or opening the release PR.

## Constraints

- **Hard CI Gate**: Never generate `pr_triage_report.md` while CI is pending
  without first halting on Step 4's `ask_question`.
- **Pre-Edit Approval Gate**: Never modify repository files or post GitHub
  replies before user approval of `pr_triage_report.md`.
- **Single-Gate VCS Execution**: Selecting a commit/push option in Step 8's
  `ask_question` authorizes committing and pushing without a second prompt.
- **Sync Code Before Comments**: Never post "Fixed" replies or resolve threads
  while code fixes remain uncommitted or unpushed.
- **Prohibitions**: Never run `git commit --amend` or `git push --force` /
  `--force-with-lease`. Always use `kscripts pr-triage` over manual API calls.
