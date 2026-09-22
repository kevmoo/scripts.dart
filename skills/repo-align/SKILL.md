---
name: repo-align
description: >-
  Audits and standardizes personal GitHub repositories (`~/github/kevmoo/*`)
  using `kscripts repo-align`, `kscripts lint-cleanup`, and `kscripts tighten`.
  Use when checking or fixing CI workflows (`lower_bound.yml`, `complexity.yml`,
  `autosubmit.yml`, `dependabot.yml`, `markdown.yml`), `.prettierrc.json`,
  `analysis_options.yaml` lints, or GitHub remote branch rulesets and
  auto-merge settings across one or all personal repositories.
---

# Personal Repository Alignment & Hygiene (`repo-align`)

Use `kscripts repo-align`, `kscripts lint-cleanup`, and `kscripts tighten` to
audit and synchronize CI workflows, markdown formatting configs, analyzer lints,
and GitHub remote repository settings across `~/github/kevmoo/*`.

## 1. Read-Only Alignment Audit (`check`)

Always begin with a non-destructive check to identify drift across local files
and remote GitHub settings:

1. **Single Repository Audit**:
   ```bash
   kscripts repo-align check -r <repo_name>
   ```
2. **Fleet-Wide Audit (`~/github/kevmoo/*`)**:
   ```bash
   kscripts repo-align check
   ```
   _(Pass `--json` when programmatically filtering or grouping drift across many
   repositories)._

### What `kscripts repo-align check` Verifies

- **Analyzer Lints (`--lints`)**: Strict mode (`strict-casts`,
  `strict-inference`, `strict-raw-types`) and canonical lint package includes in
  `analysis_options.yaml`.
- **CI Workflows & Markdown Config (`--ci`)**:
  - Standard workflow templates (`lower_bound.yml`, `complexity.yml`,
    `autosubmit.yml`, `dependabot.yml`, `publish.yaml`, `health.yaml`,
    `post_summaries.yml`, `markdown.yml`).
  - Canonical `.prettierrc.json` and absence of stray `.prettierignore` files
    (applies across all `RepoKind`s, including `agentSkills`).
  - Flags deprecated root `uses: kevmoo/analytica.dart@...` workflow references
    and narrow `.github/workflows/**` path triggers.
- **GitHub Remote Settings (`--github`)**:
  - `allow_auto_merge` enabled on the repository.
  - Presence of the `autosubmit` repository label.
  - Branch protection rulesets and required status checks matching the workflow
    matrix jobs (detects critical ungated auto-merge configurations).

## 2. Applying Fixes (`fix`) & Companion Cleanup

Separate **remote GitHub API settings** (which mutate GitHub directly) from
**local repository file changes** (which require a feature branch and Pull
Request):

### A. Remote GitHub Settings (`--github`)

After confirming with the user via `ask_question`, apply remote ruleset,
auto-merge, and `autosubmit` label fixes directly:

```bash
kscripts repo-align fix -r <repo_name> --github
```

### B. Local Repository File Fixes (`--ci` / `--lints` + `lint-cleanup` + `tighten`)

Never push file modifications directly to `main`. For each target repository:

1. **Create or Enter a Sibling Worktree** (via `/new-worktree`, e.g.
   `~/github/kevmoo/_<repo>-repo-align`).
2. **Apply Alignment & Lint Fixes**:
   ```bash
   kscripts repo-align fix -r <repo_name> --ci --lints
   kscripts lint-cleanup --package-dir <worktree_path> --rewrite
   ```
3. **Optional Dependency Tightening** _(only when requested or preparing a
   release)_:
   ```bash
   cd <worktree_path> && kscripts tighten
   ```
4. **Pre-PR Verification Gate**:
   ```bash
   cd <worktree_path>
   npx --yes prettier@3.9.6 --write "**/*.md"
   dart format --output=none --set-exit-if-changed .
   dart analyze --fatal-infos
   dart test -c source
   ```
5. **Commit, Push, & Open PR**:
   - Check `pubspec.yaml` for published packages: if at a released version
     (missing `-wip`), bump to the next `-wip` patch version and add a matching
     empty `## <version>-wip` section header in `CHANGELOG.md`.
   - Push the feature branch and open a PR via `gh pr create --body-file -`.
