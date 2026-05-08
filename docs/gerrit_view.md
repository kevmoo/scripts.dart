# New script

`gerrit_view`

# Goals

(0) Focusing 99% on the Dart SDK. If this works other places, fine, but not the goal.

(1) Get a complete view of the "state" of my work on gerrit.

  - What CLs are active for me (assigned-to-me, own) on the site
  - What branches locally are relevant to those CLs
  - What branches locally are configured for a CL that has been abandoned/closed
  - The state of "alignement" with my branches and remote
    - How do the commit SHAs align?
    - How is the 'Change-Id' aligned?



(2) LATER: maybe helpers to help me clean things up

## 🔍 Gerrit Analysis & Brainstorming

Based on a deep-dive into the local `sdk` repo configurations and queries against the Gerrit REST API, here is the current "state of the world" and the design questions we must address.

### 1. Active CLs Owned on Gerrit (Status: `NEW`/Open)
*   **CL 500341**: `[dart2wasm] Optimize math intrinsics` (WIP)
    *   *Change-Id:* `If57abc785fa6808c410215c31a1a85936d114ca8`
*   **CL 500360**: `[dart2wasm] Add math intrinsicts verification` (WIP)
    *   *Change-Id:* `Id785f02ee4415d7fbc06eb611a9318425d1ca483`
*   **CL 481980**: `[dart2wasm] Support SIMD constants and WasmF64x2.literal`
    *   *Change-Id:* `If59b17fd2cd71f0aed3653834c8c4a06f06e28a6`
*   **CL 494242**: `dart:convert: optimize indented encoding`
    *   *Change-Id:* `Ia22a9372b4e26d12f5ec7f11a6f09e8971f3c77f`
*   **CL 493200**: `[dart2wasm] normalize wat file function names`
    *   *Change-Id:* `I1c1f54e1dc201ab88f6c0f03030ffc9846ff5934`
*   **CL 493040**: `[WIP] JSON raw experiment` (WIP)
    *   *Change-Id:* `I83eb24f417e0a646a90df3572b35e157396f6e85`
*   **CL 491341**: `Flag redundant null argument values in avoid_redundant_argument_values`
    *   *Change-Id:* `I3a6ad733c3820d3bf234bd6e5c0e13eaa9773729`
*   **CL 480681**: `Update docs/External-Package-Maintenance.md`
    *   *Change-Id:* `I0cabab5498f285b2b9bb8f54427469493be9bd99`

---

### 2. Local Branch Alignment & Mismatches
By querying local branches matching `branch.*.gerritissue`, we found three distinct categories of alignment:

#### A. Perfect Alignment (Active CL, Matching Change-Id)
These branches are perfectly aligned and active:
*   `avoid_redundant_argument_values_null` ➔ CL 491341 (`I3a6ad733...`)
*   `ecosystem_bits` ➔ CL 480681 (`I0cabab54...`)
*   `json_pretty_fast` ➔ CL 494242 (`Ia22a9372...`)
*   `wasm_expect_bits` ➔ CL 500360 (`Id785f02e...`)
*   `wat_diff_better` ➔ CL 493200 (`I1c1f54e1...`)

#### B. Configured for Merged/Abandoned CLs (Cleanup Candidates)
These local branches are configured to point to CLs that are already closed or abandoned on the remote:
*   `update_pprof_generated` ➔ CL 501706 (**MERGED**)
*   `api_summary_minimal` ➔ CL 499440 (**MERGED**)
*   `print_dynamic_calls` ➔ CL 482641 (**ABANDONED**)
*   `api_diff_tool` ➔ CL 498520 (**ABANDONED**)
*   `streaming_format` ➔ CL 496120 (**ABANDONED**)
*   `main` ➔ CL 490362 (**ABANDONED**)

#### C. Active Mismatches (Change-Id Conflict or Branch Stack Confusion)
These branches are particularly interesting and indicate potential local/remote desynchronization or branch stacking:
*   `cl-after-fix` ➔ Configured for CL 500360, but local `HEAD` commit Change-Id is `If57abc...` (which belongs to **CL 500341**).
*   `wasm_const_fun` ➔ Configured for CL 481980, but local `HEAD` commit Change-Id is `I20c82...` (does not match remote `If59b1...`).
*   `json_silly` ➔ Configured for CL 493040, but local `HEAD` commit Change-Id is `I70752...` (does not match remote `I83eb2...`).
*   `restack-math-intrinsics` ➔ Configured for CL 500360, but local `HEAD` commit Change-Id is `I5b3e7...` (does not match remote `Id785f...`).
*   `fix-compact-hash-crash` ➔ Configured for CL 500360, but local `HEAD` commit Change-Id is `I4d968...` (does not match remote `Id785f...`).

---

### ❓ Design Questions, Concerns & UX Brainstorming

When multiple branches point to the same CL (e.g. `500360`), the UX should **actively guide** you on how to resolve the confusion. Rather than just displaying a warning, we can use Git's low-level metadata to score and rank the alignment of each candidate branch.

#### Heuristics for Resolving Branch Conflation (UX Guidance)

We can evaluate each branch across four alignment vectors and present a visual, color-coded comparison dashboard:

1.  **Alignment of `Change-Id` (Identity Level)**
    *   *Check:* Does the branch's `HEAD` commit contain a `Change-Id` matching the Gerrit CL?
    *   *UX Value:* If only one branch has the matching `Change-Id` at `HEAD` (e.g. `wasm_expect_bits`), it's almost certainly the primary branch. If a branch's `HEAD` contains a different `Change-Id` (e.g. `cl-after-fix` containing the ID for CL `500341`), we flag it as *Stack Conflation* or *Diverged*.

2.  **Alignment of Commit Hash (Perfect Sync Level)**
    *   *Check:* Is the local branch `HEAD` commit SHA identical to the remote `current_revision` commit hash on Gerrit?
    *   *UX Value:* If a branch matches the remote hash perfectly, it is marked as `✅ SYNCED`. This guarantees zero local divergency.

3.  **Alignment of "Tree" Hash (Content Level)**
    *   *Check:* What if the commit hashes do *not* match (e.g., you rebased locally or amended the commit message), but the actual files/code are identical?
    *   *How:* Compare the Git **Tree Hash** (`git cat-file -p <SHA>` or `git show --format=%T <SHA>`) of your local `HEAD` against the remote revision's tree.
    *   *UX Value:* If the tree hashes are identical, the branch code is perfectly up-to-date even if the commit history has diverged. We can display `✅ CONTENT IDENTICAL`.

4.  **Activity & Recency Check (Context Level)**
    *   *Check:* Compare the local commit author/committer dates and local reflogs.
    *   *UX Value:* Flag the branch with the most recent commit or checkout activity as `🔥 ACTIVE CANDIDATE`, while marking old inactive ones as `💤 STALE`.

---

#### 🎨 Draft Conflated Branch Dashboard UX

When a conflated CL is encountered, `gerrit_view` can display a structured report like this:

```
⚠️  CONFLATED CL: 500360 ([dart2wasm] Add math intrinsics verification)
   The following 4 branches are configured to target this CL.

   Branch                     Change-Id     Commit SHA    Tree (Content)  Last Commit
   ----------------------------------------------------------------------------------------
   wasm_expect_bits           ✅ MATCH      ✅ SYNCED     ✅ IDENTICAL    2 hours ago (Active Candidate)
   restack-math-intrinsics    ❌ MISMATCH   ❌ OUT OF SYNC ❌ DIFFERENT    2 days ago
   fix-compact-hash-crash     ❌ MISMATCH   ❌ OUT OF SYNC ❌ DIFFERENT    1 week ago (Stale)
   cl-after-fix               ⚠️ (For 500341)❌ OUT OF SYNC ❌ DIFFERENT    3 days ago
```

---

### ❓ Other Design Questions

1.  **Remote-Only CLs (No local tracking branch found)**:
    *   *Goal:* We will list open CLs on the site that do not have *any* corresponding local branch in their own dedicated section. This makes you aware of open work that has no local presence so you can clean them up or check out a fresh branch.
    *   *UX Format:*
        ```
        🌐 REMOTE-ONLY CLS (No local tracking branch found)
           These open CLs on the site do not have a corresponding local branch.
           
           • CL 480681: Update docs/External-Package-Maintenance.md
             URL: https://dart-review.googlesource.com/c/sdk/+/480681
        ```

2.  **Clickable Review URLs (Crucial UX)**:
    *   *Goal:* For *every* CL status view (Active, Conflated, or Remote-Only), we must provide the full clickable review URL (e.g., `https://dart-review.googlesource.com/c/sdk/+/<number>`). 
    *   *UX Value:* In modern terminal emulators (like iTerm2, VS Code terminal, Apple Terminal), absolute URLs are automatically parsed as clickable hyperlinks, allowing you to command-click directly into the Gerrit web interface instantly.

3.  **Performance & Caching (Shadow Fetch & Local Alignment)**:
    *   *The Challenge:* Relying on REST API calls to inspect remote file structures, tree hashes, or diffs is slow, fragile, and requires many HTTP requests.
    *   *The Solution (Shadow Fetch):* 
        1. We perform exactly **one** single REST query to fetch all active CLs (`owner:self status:open`), which returns their CL numbers and latest patchset numbers.
        2. We calculate their Gerrit fetch ref patterns. The ref format is:
           `refs/changes/<last_two_digits_of_CL_number>/<CL_number>/<patchset>`
           *(Example: CL 500360 patchset 9 ➔ `refs/changes/60/500360/9`)*
        3. We run `git fetch origin <ref>` for each active CL. 
           *   **Crucial Benefit:** This downloads the remote commits and metadata into your local Git object database *without* creating any visible local branches, tags, or refs. They are stored ephemerally under `FETCH_HEAD`, and standard Git garbage collection (`git gc`) will prune them automatically later.
        4. With the objects locally fetched, the tool can perform all SHA, tree hash, and commit analysis in-memory using standard, lightning-fast local Git commands against `FETCH_HEAD` (or the resolved ephemeral commit SHA).
    *   *Result:* 100% reliable alignment analysis, zero REST API overhead for code comparisons, and zero clutter in your local branches/tags workspace.

---

### 🚀 Proposed Next Steps

1.  **Define the CLI tool schema (`gerrit_view.dart`)**:
    *   Create a structured tool in `lib/src/gerrit_view.dart` and `bin/gerrit_view.dart`.
    *   Use the `gob-curl` and local git commands to gather info.
2.  **Implement Remote State Querying**:
    *   Fetch all open CLs owned by the user via `owner:self status:open`.
    *   Fetch all open CLs where the user is in the attention set or a reviewer/assignee.
3.  **Implement Local State Mapping**:
    *   Read all local branches.
    *   Extract their `gerritissue` and `gerritserver` configurations.
    *   Extract the top commit hash (`SHA`) and the `Change-Id` from the commit message.
4.  **Perform Alignment Analysis**:
    *   Match local branches with remote CLs.
    *   Highlight mismatch anomalies (e.g. "Change-Id mismatch", "Multiple branches targeting same CL", "Abandoned/Merged CL branches").
5.  **Format and Print the Report**:
    *   Design a premium console dashboard layout (using `package:io/ansi.dart`) to display the status clearly.

---

## 🛠️ Inspected Skills & References
*   `/Users/kevmoo/github/dart/sdk/.agents/skills/read_gerrit_cl` (Gerrit REST endpoints, curl, jq)
*   `/Users/kevmoo/github/kevmoo/kevmoo_skills/.agent/skills/gob-curl` (Gerrit query parameters, Buildbucket, API detail options)
*   `/Users/kevmoo/github/kevmoo/kevmoo_skills/.agent/skills/gerrit-stacked-cls` (stacked CL relation chains and squashing rules)
