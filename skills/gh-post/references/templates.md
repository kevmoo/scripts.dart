# GitHub Post Templates & Field Mappings (`/gh-post`)

Reference templates, title examples, and GitHub YAML Issue Form mappings for
[`skills/gh-post/SKILL.md`](../SKILL.md).

## Title Pattern Examples (High-Signal vs. Slop)

| Post Type   | Format Pattern                      | High-Signal Example                                               | Slop Example to Avoid                            |
| :---------- | :---------------------------------- | :---------------------------------------------------------------- | :----------------------------------------------- |
| **Bug**     | `[subsystem] Failure on condition`  | `[analyzer] Crash with NullPointer when config.json is empty`     | `Bug in analyzer` or `[CRITICAL] System failure` |
| **Bug**     | `subsystem: Failure on condition`   | `cli: Flag --output fails when target directory is missing`       | `CLI tool is broken`                             |
| **Feature** | `[subsystem] Imperative capability` | `[auth] Support PKCE flow in OAuth2 authentication client`        | `Feature request: make authentication better`    |
| **Feature** | `request: Imperative capability`    | `request: avoid cascading releases when constraints allow update` | `Feature idea for melos`                         |
| **PR**      | `type(scope): imperative summary`   | `feat(orient): add remote repo support and bot filter`            | `Updates and fixes`                              |

## 1. Bug Report Template (`draft_github_<owner>_<repo>_issue.md`)

````markdown
### Summary

1–2 sentence description of the failure and trigger condition.

### Steps to Reproduce

1. Execute `tool_name --flag value` (or minimal CLI command)
2. Pass input `<repro_input>`

### Observed Behavior

```text
<literal error output, exception message, or raw stack trace>
```

### Expected Behavior

<1–2 sentences describing the expected outcome>

### Environment / Target

- Target Commit / Version: `<commit_hash>`
- Runtime / Platform: `<e.g. Linux x86_64, Dart 3.8.0, Node 22>`
````

## 2. Feature Proposal Template (`draft_github_<owner>_<repo>_issue.md`)

```markdown
### Context & Problem

1–2 sentences explaining what problem needs to be solved.

### Proposed Solution

Concrete description of the proposed interface, behavior, or flag.

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Non-Goals

- What this feature explicitly does NOT cover
```

## 3. Pull Request Artifact Preview & Body Template (`draft_github_<owner>_<repo>_pr.md`)

Include the **Explicit 3D Paranoia Header** at the top of the local artifact
preview (`draft_github_<owner>_<repo>_pr.md`) for user review, and strip that
header line when writing `/tmp/post_body.md` for `gh pr create --body-file` so
the published GitHub PR description begins cleanly at `### Rationale`.

````markdown
🛡️ Paranoia Tier: Ring <2..4B> (<Label>) · Confidence: <High|Low> · Door: <🚪 One-Way | 🔄 Two-Way>

### Rationale

1–2 sentences explaining why this change is needed.

### Summary of Changes

- Bulleted description of the concrete code changes
- Touch only what the task requires; no orphaned imports or unrelated diffs

### Flow / Surface Delta

<!-- Include ONLY when at least one FU3 trigger holds:
     (1) public API/CLI/config surface changes,
     (2) >= 3 files have altered control-flow or state routing, or
     (3) benchmark/hot-path architecture changes.
     Otherwise omit this entire section. -->

```text
Before: CLI -> parseArgs() -> runCheck()
After:  CLI -> parseArgs() -> resolveBaseline() -> runCheck(baseline)
```

### Verification

- Executed `dart test` with 100% pass
- Verified edge case `<repro_condition>` passes

Fixes #<issue_number>
````

### Conditional `### Flow / Surface Delta` Examples (`FU3`)

- **Trigger 1 — Public API / CLI / Config Surface Change (`<= 12` lines)**:

  ```diff
  - kscripts pr-triage re-request <reviewer_login>
  + kscripts pr-triage re-request <reviewer_login> [--dismiss <review_id> -m "<reason>"]
  ```

- **Trigger 2 — Multi-File Control-Flow or State Routing (`>= 3` files, `<= 6`
  nodes, `<= 50` chars/label)**:

  ```mermaid
  flowchart LR
      A["pr_triage.dart"] --> B["github_cli.dart (dismiss)"]
      B --> C["gh pr edit --add-reviewer"]
  ```

- **Trigger 3 — Benchmark / Hot-Path Architecture Change**:

  | Metric           | Pre-Change | Post-Change | Delta (%) | Speedup |
  | :--------------- | :--------- | :---------- | :-------- | :------ |
  | Cold scan (`ms`) | `420 ms`   | `95 ms`     | `-77.4%`  | `4.42x` |

## Mapping Standard Sections to GitHub YAML Issue Forms

When a repository uses GitHub Issue Forms (`.github/ISSUE_TEMPLATE/*.yml`), the
issue body is rendered as sequential H3 markdown sections matching each form
element's `label:` attribute. Map conceptual anti-slop sections to the form's
specific fields:

| Conceptual Section     | Common YAML Field IDs               | Rendered Form Heading                                   |
| :--------------------- | :---------------------------------- | :------------------------------------------------------ |
| **Trigger Command**    | `command`, `repro_command`          | `### Command`                                           |
| **Context & Problem**  | `description`, `context`, `problem` | `### Description` or `### Context`                      |
| **Reasoning / Impact** | `reasoning`, `motivation`           | `### Reasoning`                                         |
| **Proposed Solution**  | `solution`, `proposal`, `idea`      | `### Proposed Solution`                                 |
| **Additional Context** | `additional_context`, `comments`    | `### Additional Context` (put Acceptance Criteria here) |
