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

Audits multi-section Markdown and plain-text documents by pairing deterministic
prose smell metrics (`kscripts prose-check --json`) with an Inquisitor
false-positive filter and an isolated fresh-context blind reader. Findings map
onto an orthogonal **2D `Urgency x Certainty` matrix** so benign CLI/API idioms
are dismissed, real decision and clarity blockers surface first, and approved
rewrites use plain causal English rather than telegraphic shorthand.

## Quick Start

```bash
# Scan a Markdown document for vitality ratios and top hotspot spans (exits 0):
kscripts prose-check --json --profile=auto /path/to/document.md

# Pass an explicit profile when auditing neutral scratch filenames:
kscripts prose-check --json --profile=spec /path/to/prd_draft.md
kscripts prose-check --json --profile=narrative /path/to/strategy_memo.md
kscripts prose-check --json --profile=readme /path/to/README.md

# Scan plain text (4-space indented prose analyzed rather than masked as code):
kscripts prose-check --json --format=text /path/to/notes.txt
cat /path/to/draft.md | kscripts prose-check --json -
```

> [!IMPORTANT]
>
> **Advisory Default (`exit 0`) & Anti-Theater Rule**: `kscripts prose-check`
> exits `0` on valid input even when smells exist (`--fail-on-smells` is
> opt-in). Every regex or ratio hit is a **smell signal**, not a compiler error.
> Never mangle clear CLI/API reference prose or compress natural English into
> cryptic noun-phrase shorthand just to chase a zero-smell score.

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
2. **Classify Profile & Audience**:
   - Read the opening ~30 lines (frontmatter, title, headings) to pick an
     explicit `--profile` (essential on neutral scratch filenames like
     `draft.md`):
     - `readme`: Package `README.md` or CLI/API reference (flags, config keys,
       exit codes).
     - `spec`: PRDs, RFCs, and design proposals with user journeys, scope
       tables, and open decisions.
     - `narrative`: Executive strategy memos, theses, and analytical readouts.
     - `technical`: Developer guides, walkthroughs, and operational runbooks.
3. **Classify Ownership Tier**:
   - **Tier 1 (Owned Local Draft)**: Author's own local `.md`/`.txt` file,
     feature branch, or scratch draft without active multi-author inline review
     threads. Eligible for bounded 2-pass in-place remediation on approval.
   - **Tier 2 (Shared Collaborative Doc or External Repo)**: Document with
     active review threads, peer-owned PR branch, or external repository. Keep
     target files read-only until confirmed and stage **comment-anchor-safe
     per-paragraph replacement snippets** rather than full-section rewrites.
4. **Run Token-Efficient CLI Core (`kscripts prose-check --json`)**:
   ```bash
   kscripts prose-check --json --profile=<readme|technical|spec|narrative|auto> <path>
   ```
   _(Fall back to `prose-check --json ...` if shimmed on `PATH`; pass
   `--format=text` for plain text.)_
   - Extracts exact vitality ratios (`proseWords`, `sentenceMeanWords`,
     `pctOver30Words`, `pctWordsInParens`, `pillsPer100Words`, `boldLeadPct`,
     `maxConsecutiveBoldLeads`, `maxTableCellWords`, `totalSmellCountsById`,
     `truncatedSmells`) and top stratified `line:column` hotspots in `~10 ms`
     and `~300 tokens` so the agent never counts words by eye or scans clean
     paragraphs. Never leak `prose-check` output into Step 3's blind reader.

### Step 2: Hotspot Sanity Check & Inquisitor Smell Dismissal

Read **only** the flagged `line:column` hotspot lines (`+/- 3` lines of context)
rather than trusting regex hits blindly. Drop false smells using three
**Inquisitor Dismissal Filters** before scoring:

- **`[DISMISSED: REFERENCE_IDIOM]`**: Backticked exit codes or HTTP status
  literals (such as `` `78` `` or `` `200 OK` ``), CLI option or config key
  type/default tuples (`(bool, default true; ...)`), short parenthetical
  platform or scope qualifiers on CLI reference bullets, API type signatures,
  config reference tables, and `code-pill-soup` or `paren-word-share` totals
  driven by enumerating CLI flags and config keys in `readme`/`technical` docs.
- **`[DISMISSED: INTENTIONAL_EMPHASIS]`**: Bounded `3`-to-`5` item option lists
  using `**Option A**:` labels, short term definitions, or a deliberate
  rhetorical contrast.
- **`[DISMISSED: LOW_CERTAINTY_OPINION]`**: Pure subjective word-choice
  preferences where existing prose is already clear and concise.

Record the dismissed count and filter breakdown in the report summary so the
user sees explicit signal-to-noise discipline.

### Step 3: Fresh-Context Blind Reader Pass

Spawn **one** strictly read-only subagent (`EnableWriteTools: false`, or an
isolated read-only `Explore` / `research` helper agent with file-read access
only, no shell commands, and zero authoring-conversation context) given
**only**:

1. [references/blind_reader_prompt.md](references/blind_reader_prompt.md).
2. One line stating the document `Profile` and target `Audience`.
3. The target file path.

_(In restricted worker harnesses without subagent tools, spawn a fresh read-only
helper agent with zero history, or run
[references/blind_reader_prompt.md](references/blind_reader_prompt.md) cold on
the file before synthesizing Step 2.)_

The blind reader audits **five semantic failure modes** regexes miss:

1. **30-Second Reader Ask, Decision Owners & Deadline Clarity** (without
   alarmist or fait-accompli framing; on `readme`/`technical`, clear tool
   purpose and quick-start usage).
2. **Minimum-Decision-Context Summary & Multi-Cohort Completeness** (zero
   low-level config/symbol weeds above the fold, and naming **both** active and
   pending/uninstrumented cohorts covered in the body).
3. **Telegraphic Noun-Phrase Shorthand & Coined Jargon**
   (`"without proving 1:1 displacement"` vs. plain causal English
   `"Because counts track requests rather than unique people, they show what tools fetch rather than why browser views fell"`,
   undefined labels like `"SDK Seam"`, `"PRD design stance"`, or
   `"spatial workbenches"`, and uncited `~10%-15%` guesses).
4. **Cross-Section Metric Repetition (`4x+`) & Altitude Whiplash** (repeating
   stats `4x+`, TDD internals inside a PRD, bundling unrelated workflows into
   one user journey, or 80-word repo/owner bullets that belong in a table).
5. **Internal Contradictions Across Sections or Tabs** (`Draft` vs. `Aligned`,
   `Committed` vs. `Unvalidated`, or component counts that fail to sum).

### Step 4: Orthogonal `2D Urgency x Certainty` Triage & Report

Every kept finding carries **both** an Urgency tier and a Certainty level:

- **Urgency**:
  - `🚨 P0 Decision Blocker`: Missing/buried ask, cross-section contradiction,
    omitted summary cohort, or unintelligible telegraphic shorthand / undefined
    jargon above the fold.
  - `⚠️ P1 Scan Tax`: Systemic readability drag (`>= 70%` wall-of-bold or `15+`
    consecutive bold leads, `>= 12%` non-reference paren word share, `45w+`
    run-on or semicolon mega-bullets, nested parens, `> 35w` table cells, `1D`
    micro-table spam, narrative pill overload, uncited `~X%-Y%` guesses, `4x+`
    repetition, bucket-stuffed user journeys, or TDD weeds in a spec).
  - `🧹 P2 Polish`: Isolated prose em-dashes, minor backtick nits, or a single
    long parenthetical. **Suppress `P2` completely if zero `P0` or `P1` findings
    exist!**
- **Certainty**:
  - `High`: Backed by `prose-check` metrics verified in context, exact
    conflicting line quotes (`L28` vs. `L67`), or an objectively absent ask /
    undefined coined term. Eligible for direct rewrite on approval.
  - `Medium`: Structural or comprehension signal where author intent could go
    two ways. **Surface as a concrete question or 2-way choice; never silently
    rewrite!**
  - `Low`: Auto-discarded in Step 2 (never shown).

```markdown
# Prose Review: <Document Title or Filename>

**Profile**: `<profile>` | **Ownership**: `<Tier 1 | Tier 2>` | **Verdict**: `<✅ Clean | ⚠️ Scan Tax | 🚨 Decision Blockers>`
**30s Blind-Read**: `<Pass | Fail>` | **Ask**: `<inferred ask or UNCLEAR>` (Score: `<N>/10`)
**Vitality**: `<proseWords>` words · mean `<X>`w/sent (`<Y>%` >30w) · parens `<Z>%` · bold `<B>%` · pills `<P>`/100w
**Inquisitor Filter**: Dismissed `<N>` benign hits (`<REFERENCE_IDIOM / INTENTIONAL_EMPHASIS / LOW_CERTAINTY_OPINION>`)

## Findings

- **[P0 | Certainty: High]** `L1-L45`: **<Declarative takeaway>**
  - **Evidence**: <Exact quote, conflicting line pair, or `prose-check` metric.>
  - **Fix / Choice**: <Plain causal-English rewrite for `High`, or 2-way author question for `Medium`.>
```

### Step 5: Approval Gate & Bounded 2-Pass Remediation

When zero `P0` and zero `P1` findings exist (`P2` suppressed), report `✅ Clean`
and leave the file untouched. Otherwise, gate via `ask_question` (when
available):

- **Tier 1 (Owned Local Draft)**:
  1. `"(Recommended) Apply High-certainty P0/P1 fixes in-place (2-pass rewrite) and confirm Medium choices"`
  2. `"Preview replacement diffs without editing"`
  3. `"Keep audit report only"`
- **Tier 2 (Shared Collaborative Doc with Active Threads or External Repo)**:
  1. `"(Recommended) Stage comment-anchor-safe per-paragraph replacement snippets"`
  2. `"Keep audit report only (strictly read-only)"`

**Bounded 2-Pass Rewrite Ceiling (Never Exceed 2 Passes)**:

1. **Pass 1 (Structural & Causal-English Pass)**: If Step 1 had
   `truncatedSmells > 0`, run
   `kscripts prose-check --json --profile=<profile> --top=0 <path>` first so
   every genuine hotspot across the file is visible. Apply approved `High`
   `P0`/`P1` fixes in plain causal English with explicit subjects and active
   verbs (never compress into telegraphic noun stacks). Flatten `- **Label**:`
   bullet walls into 2-to-4 sentence paragraphs, convert 80-word owner/repo
   bullets into a table, flatten `<= 2x2` micro-tables into plain bullets, and
   preserve Tier 2 comment anchors via scoped per-paragraph edits.
2. **Pass 2 (`prose-check` & Fact-Preservation Delta Pass)**: Re-run
   `kscripts prose-check --json --profile=<profile> --top=0 <path>` to confirm
   vitality improvement (and touch up any remaining non-dismissed `high` smell
   in-pass), while verifying **zero lost facts, citations, numbers, or modal
   qualifiers** (`proposed` vs. `shipped`, `projected` vs. `committed`). Stop
   after Pass 2.
