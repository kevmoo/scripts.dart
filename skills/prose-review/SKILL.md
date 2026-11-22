---
name: prose-review
description: >-
  Audits Markdown and plain-text documents for prose readability smells,
  comprehension barriers, missing reader asks, and structural drift, then guides
  surgical causal-English remediation. Use when invoking /prose-review or
  reviewing design docs, PRDs, RFCs, strategy memos, analytical readouts, and
  READMEs before sharing or publishing. Don't use for reviewing code diffs (use
  pr-review), triaging existing pull request comments or CI failures (use
  pr-triage), or checking quick 3-line triage clarity on short issues and pull
  requests (use cold-read).
---

# Prose & Document Clarity Reviewer (`/prose-review`)

Audits Markdown and plain-text documents by pairing deterministic prose smell
metrics (`kscripts prose-check --json`) with an Inquisitor false-positive filter
and an isolated fresh-context blind reader. Findings map onto an orthogonal **2D
`Urgency x Certainty` matrix** so benign CLI/API idioms are dismissed, real
decision blockers surface first, and approved rewrites use plain causal English.

## Quick Start

```bash
# Scan Markdown for vitality ratios and top hotspot spans (exits 0):
kscripts prose-check --json --profile=auto /path/to/document.md

# Pass an explicit profile on neutral scratch filenames:
kscripts prose-check --json --profile=spec /path/to/prd_draft.md
kscripts prose-check --json --profile=narrative /path/to/strategy_memo.md
kscripts prose-check --json --profile=readme /path/to/README.md

# Scan plain text or stdin:
kscripts prose-check --json --format=text /path/to/notes.txt
cat /path/to/draft.md | kscripts prose-check --json -
```

> [!IMPORTANT]
>
> **Advisory Default (`exit 0`) & Anti-Theater Rule**: `kscripts prose-check`
> exits `0` by default (`--fail-on-smells` is opt-in). Every hit is a **smell
> signal**, not a compiler error. Never mangle clear CLI/API reference prose or
> compress English into cryptic noun-phrase shorthand to chase zero smells.

---

## Execution Protocol

### Step 1: Input, Profile & Ownership Resolution + CLI Core Scan

1. **Locate or Export Lossless Markdown**:
   - Read local `.md` or `.txt` files directly.
   - For collaborative rich-text documents exported from web editors, pull a
     **lossless Markdown snapshot** into a session scratch file rather than a
     plain-text scrape. Plain-text scrapes strip `**bold**` markers, inline
     `` `code` `` spans, and table pipes, hiding wall-of-bold monotony while
     turning table rows into fake 100-word sentences.
   - Because rich-text Markdown exporters often drop embedded raster diagrams or
     inline images silently, list or check document images alongside export, and
     on **multi-tab documents**, pull all companion tabs and verify cross-tab
     heading titles and link labels.
2. **Classify Profile & Audience**:
   - Read the opening ~30 lines (frontmatter, title, headings) to confirm or
     override `--profile` (`--profile=auto` inspects filename keywords plus
     top-60-line headings and reports `profileReason` in JSON):
     - `readme`: Package `README.md` or CLI/API reference (flags, config keys,
       exit codes).
     - `spec`: PRDs, RFCs, scope proposals, and design docs (`Executive Summary`
       with `Proposed Scope`, `Non-Goals`, `Open Questions`, `User Journeys`).
     - `narrative`: Executive strategy memos, theses, and analytical readouts.
     - `technical`: Developer guides, walkthroughs, and operational runbooks.
3. **Classify Ownership Tier**:
   - **Tier 1 (Owned Draft)**: Author's own draft or branch without active
     inline review threads. Eligible for bounded 2-pass in-place remediation on
     approval.
   - **Tier 2 (Shared Doc With Active Threads or External Repo)**: Document with
     active inline review threads, peer-owned PR branch, or external repository.
     Keep target files read-only until confirmed and stage **comment-anchor-safe
     per-paragraph replacement snippets** rather than full-section rewrites.
4. **Run Token-Efficient CLI Core (`kscripts prose-check --json`)**:
   ```bash
   kscripts prose-check --json --profile=<readme|technical|spec|narrative|auto> <path>
   ```
   _(Fall back to `prose-check --json ...` if shimmed on `PATH`; pass
   `--format=text` for plain text.)_
   - Extracts exact vitality ratios (`proseWords`, `proseBlocks` as the
     denominator of `boldLeadPct` across all non-heading paragraphs and list
     items including nested sub-bullets, `sentenceMeanWords`, `pctOver30Words`,
     `pctWordsInParens`, `pillsPer100Words`, `rawSymbolsPer100Words` for
     backtick-stripped `snake_case` / `package:` / `.h` symbols, `boldLeadPct`,
     `maxConsecutiveBoldLeads`, `maxTableCols`, `maxTableCellWords`),
     profile-calibrated `thresholds`, `profileReason`, `totalSmellCountsById`,
     and stratified `line:column` hotspots with context excerpts in `~15 ms` and
     `~350 tokens`. Never leak `prose-check` output into Step 3's blind reader.

### Step 2: Hotspot Sanity Check & Inquisitor Smell Dismissal

If `truncatedSmells > 0`, re-run with `--top=0` first so every hotspot is
visible. Read **only** the flagged `line:column` hotspot lines (`+/- 3` lines of
context) rather than trusting regex hits blindly, and drop false smells using
three **Inquisitor Dismissal Filters** before scoring:

- **`[DISMISSED: REFERENCE_IDIOM]`**: Header metadata rosters (`Author`,
  `Stakeholders`, `Reviewers` with `(@handle)` chips), backticked version
  strings (such as `` `1.0` ``, `` `3.x` ``, or `` `1.2.0` ``), CLI exit codes
  or HTTP status literals (such as `` `78` `` or `` `200 OK` ``),
  `Framework/Language` stack pairs (`Flutter/Dart`, `React/TypeScript`) and
  `org/repo` slugs, CLI option or config key type/default tuples
  (`(bool, default true; ...)`), short parenthetical platform or scope
  qualifiers on CLI reference bullets, API type signatures, config reference
  tables, and `code-pill-soup` or `paren-word-share` totals driven by
  enumerating CLI flags, paths, and config keys in `readme`, `technical`, or
  CLI/API walkthrough sections of `spec` docs.
- **`[DISMISSED: INTENTIONAL_EMPHASIS]`**: Bounded `3`-to-`5` item option lists
  using `**Option A**:` labels, repeated structured ledger/schema labels across
  parallel sections (such as `**Verified Today (Oct 2026)**`), short term
  definitions, deliberate rhetorical contrasts, or `smell`-tier `wall-of-bold`
  hits in `spec`/`technical` docs when short conclusion-first bullets are used
  uniformly under clear section prose without mixing nested sub-bullets and flat
  bold leads across sections.
- **`[DISMISSED: LOW_CERTAINTY_OPINION]`**: Pure subjective word-choice
  preferences where existing prose is already clear and concise.

Record the dismissed count and filter breakdown in the report summary.

### Step 3: Fresh-Context Blind Reader Pass & Citation Verification

Spawn **one** strictly read-only subagent (`EnableWriteTools: false`, or an
isolated read-only `Explore` / `research` helper agent with file-read access
only, no shell commands, and zero authoring-conversation context):

1. **Inline the Rubric (and Guard Against Prompt Truncation)**: Read
   [references/blind_reader_prompt.md](references/blind_reader_prompt.md)
   yourself and paste its full instructions **inline** into the subagent's
   prompt alongside `Profile`, target `Audience`, and the target file path so
   the subagent's **single** `read_file` call reads only the target document.
   When a small exported snapshot (`<= 30 KB` / `~250` lines) sits in a scratch
   directory outside a built-in subagent's workspace sandbox, you may pass
   `1: ...`-prefixed physical lines inline; for larger documents (`> 30 KB`),
   never inline the document body (which risks prompt-cap tail truncation)—use a
   custom read-only subagent (`EnableWriteTools: false`) that calls `read_file`
   directly on the scratch file path.
2. **Inquisitor Line-Citation Check**: Before merging Step 3 findings into Step
   4, verify every cited line or line pair (`L28 vs. L67`) against the target
   file. Fix off-by-a-few line numbers, downgrade overstated urgency, and drop
   any claim not backed by the actual lines.

_(In restricted worker harnesses without subagent tools, spawn a fresh read-only
helper agent with zero history, or run
[references/blind_reader_prompt.md](references/blind_reader_prompt.md) cold on
the file before synthesizing Step 2.)_

The blind reader audits **five semantic failure modes** regexes miss:

1. **30-Second Purpose & Reader Ask** (clear problem, proposal, or requested
   feedback above the fold without alarmist framing; on `readme`/`technical`,
   clear tool purpose and quick-start usage).
2. **Minimum-Decision-Context Summary & Multi-Cohort Completeness** (zero
   low-level config/symbol weeds above the fold, and naming **both** active and
   pending/uninstrumented cohorts covered in the body).
3. **Telegraphic Noun-Phrase Shorthand, Coined Jargon & Unanchored Time**
   (`"without proving 1:1 user churn"` vs. plain causal English
   `"Because server logs count automated retries alongside human visits, request totals show traffic volume rather than user churn"`,
   undefined labels or metaphors like `"Integration Seam"`, `"Spec Stance"`, or
   `"flagship migration"`, dateless relative phrases like
   `"over the next two weeks"` or `"right now"`, and uncited `~10%-15%`
   guesses).
4. **Cross-Section Repetition (`4x+`), Wide-Table Drag & Altitude Whiplash**:
   Repeating stats `4x+`, `8+` column tables or ambiguous `"the table"`
   references near multiple tables, jarring shifts between nested sub-bullets
   and flat bold leads across sections, adjacent sections with overlapping
   roles, dedicated `Technical Architecture` / TDD sections inside a `spec` PRD
   (`[P1 | Certainty: Medium]` 2-way question), `CUJ` / `User Journey` headings
   that bundle `3+` distinct workflows, or 80-word repo/owner bullets that
   belong in a table.
5. **Internal Contradictions & Table-to-Prose Drift** (`Draft` vs. `Aligned`,
   `Committed` vs. `Unvalidated`, prose ordinal or count claims like
   `"fourth overall"` that no longer match table rows, asymmetric paired table
   rows where one row specifies a CLI flag and its opposite omits it, or table
   rows like `"none identified"` that violate an inclusion rule stated in
   prose).

### Step 4: Orthogonal `2D Urgency x Certainty` Triage & Report

Every kept finding carries **both** an Urgency tier and a Certainty level:

- **Urgency**:
  - `🚨 P0 Decision Blocker`: Missing/buried ask, cross-section or table-vs-rule
    contradiction, stale ordinal/count claim vs. table rows, omitted summary
    cohort, or unintelligible telegraphic shorthand / undefined jargon above the
    fold.
  - `⚠️ P1 Scan Tax`: Systemic readability drag exceeding profile `thresholds`
    (`high`-severity `wall-of-bold` or non-uniform `smell`-tier bold walls,
    `high`-severity `paren-word-share`, `45w+` run-on or `2+` semicolon chains,
    nested parens, `> 35w` table cells, `8+` column `wide-table` grids, `1D`
    micro-table spam, narrative pill overload, uncited `~X%-Y%` guesses,
    unanchored relative dates, `4x+` repetition, bucket-stuffed user journeys,
    or TDD weeds in a spec).
  - `🧹 P2 Polish`: Isolated prose em-dashes, minor backtick nits, `6-7` column
    tables, or a single `29-35w` semicolon sentence. **Suppress `P2` completely
    if zero `P0` or `P1` findings exist!**
- **Certainty**:
  - `High`: Backed by `prose-check` metrics verified in context, exact
    conflicting line quotes (`L28` vs. `L67`), or an objectively absent purpose
    / undefined coined term. Prose/mechanical `High` items rewrite directly on
    approval; **author-fact gaps** must ask the author rather than inventing
    unstated facts.
  - `Medium`: Structural or comprehension signal where author intent could go
    two ways. **Surface as a concrete question or 2-way choice; never silently
    rewrite!**
  - `Low`: Auto-discarded in Step 2 (never shown).

```markdown
# Prose Review: <Document Title or Filename>

**Profile**: `<profile>` (`<profileReason>`) | **Ownership**: `<Tier 1 | Tier 2>` | **Verdict**: `<✅ Clean | ⚠️ Scan Tax | 🚨 Decision Blockers>`
**30s Blind-Read**: `<Pass | Fail>` | **Ask**: `<inferred ask or UNCLEAR>` (Score: `<N>/10`)
**Vitality**: `<proseWords>` words · mean `<X>`w/sent (`<Y>%` >30w) · parens `<Z>%` · bold `<B>%` of `<proseBlocks>` blocks (run `<R>`) · pills `<P>`/100w · tables `<T>` (max `<C>` cols, `<W>`w cell)
**Inquisitor Filter**: Dismissed `<N>` benign hits (`<REFERENCE_IDIOM / INTENTIONAL_EMPHASIS / LOW_CERTAINTY_OPINION>`)

## Findings

- **[P0 | Certainty: High]** `L1-L45`: **<Declarative takeaway>**
  - **Evidence**: <Exact quote, conflicting line pair, or `prose-check` metric.>
  - **Fix / Choice**: <Plain causal-English rewrite, author question for missing facts, or 2-way choice for `Medium`.>
```

### Step 5: Approval Gate & Bounded 2-Pass Remediation

When zero `P0` and zero `P1` findings exist (`P2` suppressed), report `✅ Clean`
and leave the file untouched. Otherwise, gate via `ask_question` (when
available):

- **Tier 1 (Owned Draft)**:
  1. `"(Recommended) Apply High-certainty P0/P1 fixes in-place (2-pass rewrite) and confirm Medium/author-fact choices"`
  2. `"Preview replacement diffs without editing"`
  3. `"Keep audit report only"`
- **Tier 2 (Shared Doc With Active Threads or External Repo)**:
  1. `"(Recommended) Stage comment-anchor-safe per-paragraph replacement snippets"`
  2. `"Keep audit report only (strictly read-only)"`

**Bounded 2-Pass Rewrite Ceiling (Never Exceed 2 Passes)**:

1. **Pass 1 (Structural & Causal-English Pass)**: If `truncatedSmells > 0`, run
   `kscripts prose-check --json --profile=<profile> --top=0 <path>` first so
   every hotspot is visible. Apply approved `High` `P0`/`P1` prose fixes in
   plain causal English with explicit subjects and active verbs: never compress
   into telegraphic noun stacks, never invent unstated facts, and never delete
   `Medium`-certainty sections like a PRD `Technical Architecture` section
   without confirmation. **Anti-Whack-a-Mole Rule**: Never trade deleted
   parentheses `(aside)` into paired em-dashes (`paired-em-dash`) or semicolon
   chains; rewrite mid-sentence examples or acronyms as a separate sentence or a
   plain `such as ...` / `including ...` clause. Flatten `- **Label**:` bullet
   walls into 2-to-4 sentence paragraphs, split or trim `8+` column tables, move
   80-word owner/repo bullets into a table, flatten `<= 2x2` micro-tables, and
   preserve Tier 2 comment anchors via per-paragraph edits.
2. **Pass 2 (`prose-check` & Fact-Preservation Delta Pass)**: Re-run
   `kscripts prose-check --json --profile=<profile> --top=0 <path>`. Require
   **`0` newly introduced `high`-severity smells** (`paired-em-dash`,
   `nested-parens`, `2+` semicolon or `> 35w` `prose-semicolon-chain`,
   `wide-table` `8+` cols) and fix **every** remaining non-dismissed `high`
   smell (leaving only irreducible `[DISMISSED: REFERENCE_IDIOM]` CLI/code
   spans), while confirming **zero lost facts, links, numbers, or modal
   qualifiers** (`proposed` vs. `shipped`, `projected` vs. `committed`). Stop
   after Pass 2.
