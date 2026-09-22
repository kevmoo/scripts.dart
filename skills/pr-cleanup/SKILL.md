---
name: pr-cleanup
description: >-
  Orchestrates multi-repo GitHub PR, Gerrit CL, local Git worktree, and branch
  cleanup sweeps alongside active open-PR next-step triage using `kscripts`.
  Use when asked to run a PR cleanup sweep, prune merged worktrees/branches,
  analyze current open PRs and next steps, or reconcile local checkouts in
  `~/github` against GitHub/Gerrit and active Jetski sessions.
---

# PR & Worktree Cleanup Sweep (`pr-cleanup`)

Use the `kscripts` AOT CLI (`kevmoo_scripts`, installed via `dart install`) to
audit and clean up merged/closed GitHub Pull Requests, Dart SDK Gerrit CLs,
sibling Git worktrees (`~/github/_<repo>-<branch>`), and local/remote feature
branches while protecting in-flight agent sessions.

## 1. Read-Only Pre-Flight Sweep (Always Start Read-Only)

Never pass `--apply` on the initial scan. Execute the 3 read-only collectors in
parallel to build a unified view of `~/github`:

1. **Merged/Closed PRs, Stale Worktrees & Dangling Remote Branches**:
   ```bash
   kscripts gh-clean -l 50 --markdown
   ```
2. **Open Active GitHub PRs & Reviewer/CI Next Steps**:
   ```bash
   kscripts gh-view -d 14 --markdown
   ```
   _(Omit `-d 14` if the user asks for all open PRs regardless of recency, or
   adjust `-d <days>` to match the user's window)._
3. **Dart SDK Gerrit Worktrees & CL Status** _(when `~/github/dart-sdk`
   exists)_:
   ```bash
   kscripts gerrit-view -p ~/github/dart-sdk
   ```
4. **Open Assigned GitHub Issues** _(optional — run when asked for broader
   backlog/next-steps triage)_:
   ```bash
   kscripts gh-issues --linked-prs --markdown
   ```

## 2. Active Session & PM-OS Ownership Cross-Reference

Before proposing to delete any worktree, local branch, or unpushed commit:

1. **Inspect Dirty / Unpushed Worktrees**:
   - For any worktree flagged by `kscripts gh-clean` as having uncommitted
     changes or unpushed commits, run:
     ```bash
     git -C <worktree_path> status -s
     git -C <worktree_path> log -n 2 --oneline
     ```
   - **Squash-Merge Ancestry Check**: If `gh-clean` reports
     `Error: Branch has unpushed commits past PR HEAD (<sha>)` on a merged PR
     branch, check whether the branch is actually an ancestor of `origin/main`:
     ```bash
     git -C <repo_path> rev-list --count origin/main..<branch>
     ```
     If the count is `0`, the branch was reset onto the squash-merge commit and
     is safe to delete via `git -C <repo_path> branch -D <branch>`.
2. **Cross-Reference Active Jetski Conversations & PM-OS Tasks**:
   - Check `~/.gemini/jetski/annotations/*.pbtxt` and search session transcripts
     (`~/.gemini/jetski/brain/*/.system_generated/logs/transcript.jsonl`) for
     the worktree folder name (`_<repo>-<branch>`) or PR number.
   - If the worktree belongs to an **active (`🟢` / `🧪`)** sister session or an
     open PR/CL, classify it in **Bucket A (`🚫 DO NOT TOUCH`)**.
   - If the worktree belongs to a **waiting (`⏳` / `🔔`)** session whose PR/CL
     has already **merged**, include closing that session (`pm-convo --done`)
     and any associated PM-OS task (`pm-work complete "#XXXX"`) in **Bucket B**.

## 3. Three-Bucket Classification & Report

Present the findings in a structured Markdown report (or artifact for large
sweeps) divided into 3 buckets:

- **Bucket A — `🚫 Active / Hands-Off` (Open PRs, Active Gerrit CLs, In-Flight
  Worktrees)**:
  - List open PRs from `kscripts gh-view` and active Gerrit CLs from
    `kscripts gerrit-view` with their CI status, reviewer state (`⏳ Awaiting`
    vs `🔔 Ping Reviewer` vs `❌ Action Needed`), and local worktree mapping.
- **Bucket B — `✅ Safe to Prune Immediately` (Merged PRs/CLs & Clean
  Worktrees)**:
  - Clean worktrees (`git worktree remove`), merged local feature branches
    (`git branch -D`), dangling remote head branches on writable repos, and
    trunk fast-forwards (`--ff-only`).
  - List any waiting Jetski conversations or PM-OS tasks whose PRs have landed
    and are ready to be marked `☑️ --done`.
- **Bucket C — `⚠️ Requires Explicit Confirmation` (Closed-Unmerged PRs, Dirty
  Worktrees, Unpushed Experiments)**:
  - Detail the exact modified/untracked files (`git status -s`) or unmerged
    commits so the user can decide whether to discard or keep each item.

## 4. Approval Gate & Execution

Gate execution via `ask_question` with explicit bucket choices:

- `(Recommended) Execute Bucket B only (prune merged PRs, clean worktrees & remote branches)`
- `Execute Bucket B + Bucket C (also force-remove dirty/closed-unmerged worktrees)`
- `Stop here (keep read-only report only)`

Once approved:

1. Run `kscripts gh-clean --repo <owner/repo> --apply` for each approved
   repository (or `kscripts gh-clean -l 50 --apply` for a full Bucket B sweep).
2. For approved Bucket C dirty worktrees, run
   `git -C <parent_repo> worktree remove --force <worktree_path>` and
   `git -C <parent_repo> branch -D <branch>`.
3. Mark completed sister conversations `☑️ --done` (`pm-convo`) and close landed
   PM-OS tasks (`pm-work complete "#XXXX"`).
