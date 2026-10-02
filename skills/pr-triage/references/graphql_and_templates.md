# PR Triage Report Templates, Resolution Mechanics & GraphQL Reference (`/pr-triage`)

Detailed report artifact skeletons, Step 8 completion menus, and GitHub GraphQL
/ REST schemas for [`skills/pr-triage/SKILL.md`](../SKILL.md).

## 1. `pr_triage_report.md` Artifact Skeleton & Step 6 Gate

Create `pr_triage_report.md` in `<appDataDir>/brain/<conversation-id>/` using
`write_to_file` with `RequestFeedback: false` and `UserFacing: true` in
`ArtifactMetadata`, then immediately call `ask_question` in Step 6:

- Option 1: `(Recommended) Implement the proposed fixes and test plan`
- Option 2: `Adjust the triage plan first`
- Option 3: `Do not edit files (keep triage report only)`

```markdown
# PR Triage Report: `<owner>/<repo>#<PR>`

- **PR**: [`<title>`](https://github.com/<owner>/<repo>/pull/<PR>)
- **Raw Triage Snapshot**: [`raw_triage_output.md`](file:///<appDataDir>/brain/<conversation-id>/raw_triage_output.md)
- **Branch / Sync Status**: `<headRefName>` (`<in_sync | behind_remote | ahead_of_remote | diverged>`)
- **Mergeable Status**: `<MERGEABLE | CONFLICTING>`

## Action Items

### 1. `<Concise Action Item Title>`

- **Summary of Feedback / Failure**:
  - [Comment #1 by @reviewer_username](https://github.com/<owner>/<repo>/pull/<PR>#discussion_r<id>) (or [Review #1 by @reviewer_username](https://github.com/<owner>/<repo>/pull/<PR>#pullrequestreview-<id>))
  - `<1–2 sentence summary of the reviewer claim or CI failure>`
- **Identifiers**:
  - `Thread ID`: `PRRT_...` · `Comment ID`: `<database_id>` (or `Review ID`: `PRR_...` · `Database ID`: `<review_database_id>`)
- **Agent Assessment**:
  - **Agreement Level**: `<🔥 Urgent [Valid — Fix] | 👍 Solid [Valid — Fix] | 🤷 Meh | 👎 Disagree>`
  - **Empirical Verification**: `<Output of dart analyze / dart test on unmodified code>`
  - **Rationale**: `<Technical explanation of why we agree, disagree, or recommend a direction>`
  - **Review-Escape Capture (`[Valid — Fix]` only)**: `<Logged via /sharpen-later (--cat=review-escape) | N/A>`
- **Planned Action**:
  - **Code / Doc Changes**: [`lib/src/foo.dart`](file:///.../lib/src/foo.dart#L10-L25) — `<proposed change or "No action needed">`
  - **Test Plan (2-Bucket TDD Filter)**:
    - `<Companion Test: test/foo_test.dart — test case summary>` OR `<None — copy/comment/rename or behavior already covered>`
```

## 2. Step 8 Unified Completion Menu (`ask_question`)

Include the `"dismiss stale CHANGES_REQUESTED review"` option whenever an open
`CHANGES_REQUESTED` review was fully addressed by code fixes; promote it to
`(Recommended)` when another maintainer has already `APPROVED` the PR.

### A. When Uncommitted Changes or Unpushed Commits Exist

1. `(Recommended) Commit fixes, push branch, reply/resolve, and re-request review if needed`
2. `Commit fixes, push branch, reply/resolve, dismiss stale CHANGES_REQUESTED review, and re-request review`
   _(include when an addressed `CHANGES_REQUESTED` review exists)_
3. `Commit fixes and push branch only`
4. `Commit fixes locally only`
5. `Do nothing`

### B. When Working Tree Is Clean and All Commits Are Pushed

1. `(Recommended) Reply/resolve and re-request review if needed`
2. `Reply/resolve, dismiss stale CHANGES_REQUESTED review, and re-request review`
   _(include when an addressed `CHANGES_REQUESTED` review exists)_
3. `Do nothing`

## 3. Thread Resolution, Review Dismissal & Re-Request Mechanics

### CLI Commands (`kscripts pr-triage`)

```bash
# Reply to an inline comment and resolve its review thread:
kscripts pr-triage resolve --dir <repo-path> <thread_graphql_id> <comment_database_id> "<reply_body>"

# Resolve an inline review thread without posting a reply:
kscripts pr-triage resolve --dir <repo-path> <thread_graphql_id>

# Re-request review (with optional top-level reply comment):
kscripts pr-triage re-request --dir <repo-path> <reviewer_login> \
  [--comment "<top_level_reply_body>"]

# Dismiss an addressed CHANGES_REQUESTED review AND re-request review atomically:
kscripts pr-triage re-request --dir <repo-path> <reviewer_login> \
  [--comment "<top_level_reply_body>"] \
  --dismiss <review_database_id> \
  -m "Addressed in <short_sha> (<concise summary>); re-requesting review from @<reviewer_login>."
```

### Post-Push Queue & State Verification

- **If no new commits were pushed in Step 8**: Rely directly on the
  `**Review Requests**` line and `> [!IMPORTANT] Reviewer Dropped from Queue`
  banner in `raw_triage_output.md` (do **not** make an extra `gh pr view` call).
- **If new commits were pushed in Step 8**: Check post-push state (in case
  `dismiss_stale_reviews` in repositories like `flutter/flutter` dismissed a
  prior `APPROVED` review and dropped the reviewer from `reviewRequests`):
  ```bash
  gh pr view <pr_number> -R <owner/repo> --json reviewDecision,latestReviews,reviewRequests
  ```
  If a previously `APPROVED` reviewer is now `DISMISSED` and absent from
  `reviewRequests`, run
  `kscripts pr-triage re-request --dir <repo-path> <reviewer_login>` so the PR
  re-enters their review queue.
- **GitHub State-Machine Quirk (`reviewDecision` vs. `latestReviews`)**:
  Re-requesting review without `--dismiss` adds `<login>` back to
  `reviewRequests` (`🟡 Re-review Requested`) and hides `<login>` from
  `latestReviews`, while `reviewDecision` remains `"CHANGES_REQUESTED"` until
  `<login>` approves or the review is dismissed. Conversely, dismissing a review
  without `--add-reviewer` drops `<login>` from `reviewRequests`. Running
  `kscripts pr-triage re-request <login> --dismiss <id>` executes both
  atomically.

## 4. Underlying GitHub GraphQL & REST Schemas

Always prefer `kscripts pr-triage` over raw `gh api` calls. The underlying
queries and mutations executed by `kscripts pr-triage` are documented below for
debugging and schema reference.

### Fetch PR Comments, Reviews & Review Threads (`GraphQL`)

```graphql
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      comments(last: 100) {
        nodes {
          databaseId
          author { login }
          body
          createdAt
          url
        }
      }
      reviews(last: 100) {
        nodes {
          id
          databaseId
          author { login }
          body
          state
          submittedAt
          url
        }
      }
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              databaseId
              author { login }
              body
              path
              line
              originalLine
              createdAt
              url
            }
          }
        }
      }
    }
  }
}
```

### Resolve Review Thread (`GraphQL` Mutation)

```graphql
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      isResolved
    }
  }
}
```

### Reply to Inline Comment & Dismiss Stale Review (`REST`)

```bash
# Reply to an inline review comment by numeric databaseId:
gh api repos/<owner>/<repo>/pulls/<pr>/comments/<comment_database_id>/replies \
  -f body="<reply_body>"

# Dismiss a stale CHANGES_REQUESTED review by numeric review_database_id:
gh api -X PUT repos/<owner>/<repo>/pulls/<pr>/reviews/<review_database_id>/dismissals \
  -f message="<audit_reason>"
```
