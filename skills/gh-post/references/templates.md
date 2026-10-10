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

Always place `# <Proposed Title>` on Line 1 of the draft artifact (stripped via
`tail -n +3` when passing `--body-file -` to `gh issue create`), and open Line 1
of the body directly with the exact problem statement (unlabelled BLUF; no
`### Summary` or historical preamble):

````markdown
# [subsystem] Imperative or descriptive defect title

1-sentence statement of the exact broken behavior and trigger condition (never open with historical backstory).

- **Root cause**: [`<file>#L<start>-L<end>`](https://github.com/<owner>/<repo>/blob/<commit>/<file>#L<start>-L<end>) <concise factual explanation>.
- **Impact**: <1-sentence user or build impact>.

### Proposed Fix

- <Concrete, completable change 1>
- <Concrete, completable change 2>

<details>
<summary><b>Detailed reproduction & compiler/CLI output (AI-assisted)</b></summary>

1. Execute `tool_name --flag value` on `<commit_hash>`:

```text
<literal error output, exception message, or raw stack trace>
```

</details>
````

### 1B. Performance / Multi-Cause Bug Report Template (Tight Summary + `<details>`)

Use this structure when filing multi-cause performance, bundle-size, or
deep-investigation issues (scoped to a single owning team/subsystem) so
maintainers can triage the top-level human gist in `< 15` seconds while
encapsulating raw traces and reproducibility tables inside `<details>`:

```markdown
# [subsystem] Imperative performance or multi-cause defect title

1-sentence summary of the defect, measured overhead, and trigger condition on `<route_or_command>` (`@ <commit>`):

1. **<Root Cause 1> (`<metric>`)**: [`<file>#L<start>-L<end>`](https://github.com/<owner>/<repo>/blob/<commit>/<file>#L<start>-L<end>) <1-sentence explanation>.
2. **<Root Cause 2> (`<metric>`)**: [`<file>#L<start>-L<end>`](https://github.com/<owner>/<repo>/blob/<commit>/<file>#L<start>-L<end>) <1-sentence explanation>.

Addressing these reduces:
- **<Metric 1>**: **from `<pre>` to `<post>` (`<N>x` smaller/faster)**
- **<Metric 2>**: **from `<pre>` to `<post>` (`<N>x` smaller/faster)**

<details>
<summary><b>Detailed Breakdown, Repro Steps & Measurements (AI-assisted)</b></summary>

### Steps to Reproduce

1. <Step 1>
2. <Step 2>

### Pre-Change vs. Post-Change Measurements

| Metric | Pre-Change (`<commit>`) | Post-Change | Delta (%) | Speedup / Reduction |
| :--- | :--- | :--- | :--- | :--- |
| **<Metric>** | `<pre>` | `<post>` | `<pct>%` | **`<N>x`** |

</details>
```

## 2. Feature Proposal Template (`draft_github_<owner>_<repo>_issue.md`)

```markdown
# request: imperative capability summary

1-sentence statement of the capability gap or problem to solve (no historical preamble).

### Proposed Solution

- Concrete description of the proposed interface, behavior, or flag
- Key edge case or compatibility handling

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
```

## 3. Pull Request Artifact Preview & Body Template (`draft_github_<owner>_<repo>_pr.md`)

Include `# <Proposed Title>` on Line 1 and the **Explicit 3D Paranoia Header**
on Line 3 of the local artifact preview (`draft_github_<owner>_<repo>_pr.md`)
for user review, and strip lines 1–4 (`tail -n +5`) when passing `--body-file -`
to `gh pr create` so the published GitHub PR description begins with the
one-sentence change summary. A reviewer decides from that first sentence: what
changed, why, and how it was verified. No `### Rationale` header over a single
paragraph.

````markdown
# feat(scope): imperative summary

🛡️ Paranoia Tier: Ring <0..4B> (<Label>) · Confidence: <High|Low> · Door: <🚪 One-Way | 🔄 Two-Way>

<What changed and why, in one sentence.> Verified: <command or CI job, result>. Fixes #<issue_number>.

- <Concrete change 1, with a file path or permalink>
- <Concrete change 2; touch only what the task requires>

### Verification

<!-- Only when verification needs more than the one line above:
     exact commands, edge cases exercised, before/after numbers. -->

- Executed `dart test` with 100% pass
- Verified edge case `<repro_condition>` passes

<details>
<summary><b>Flow / Surface Delta and design notes (AI-assisted)</b></summary>

<!-- Include ONLY when at least one FU3 trigger holds:
     (1) public API/CLI/config surface changes,
     (2) >= 3 files have altered control-flow or state routing, or
     (3) benchmark/hot-path architecture changes.
     Otherwise omit this entire block. -->

```text
Before: CLI -> parseArgs() -> runCheck()
After:  CLI -> parseArgs() -> resolveBaseline() -> runCheck(baseline)
```

</details>
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
