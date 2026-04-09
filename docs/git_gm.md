# Design: `git_gm` (Go Main / Go Master / Go Home)

## Goal
A script to quickly return to the default branch of a Git repository and update it.

## Key Features
1. **Identify the Default Branch**:
   - Query `origin/HEAD` to see what the remote considers the default branch.
   - Fallback to `main` then `master` if `origin/HEAD` is not set.
2. **Safety Checks**:
   - Check if the working tree is dirty (modified files, staged changes).
   - Prompt or fail if dirty, unless a force flag is used.
3. **Execution**:
   - Checkout the default branch.
   - Run `git pull --ff-only`.

## Design Considerations

### How to find the branch tracking `origin/HEAD`?
We can use:
```bash
git rev-parse --abbrev-ref origin/HEAD
```
This returns `origin/main` or `origin/master`. We can then strip the `origin/`
prefix. If it fails (e.g., `origin/HEAD` doesn't exist), we will exit with a
non-zero exit code and instruct the user how to configure it. To be helpful,
we will sniff for local or remote branches named `main` or `master` and
include that in the suggestion (e.g., `git remote set-head origin main`).

### Are there flags to make sure checkout doesn't work if the tree is dirty?
We will rely on `git checkout`'s default behavior. It refuses to switch
branches if local changes would be overwritten. This keeps the implementation
simple and carries over non-conflicting changes, which is usually fine.

### If `origin/HEAD` succeeds, how to confirm a local branch aligns with it?
Yes, we can check the tracking configuration.
If `origin/HEAD` tells us the default branch is `main`, we can check if the
local `main` branch tracks `origin/main` by running:
```bash
git rev-parse --abbrev-ref main@{u}
```
If it returns `origin/main`, it aligns! If it fails or returns something else,
we know the local branch is not tracking the remote default branch.

We can also check the config keys directly:
- `branch.main.remote` (should be `origin`)
- `branch.main.merge` (should be `refs/heads/main`)

If it doesn't align, we will warn the user exactly why we stopped and how
they can configure things to fix the problem (e.g., by running `git branch
--set-upstream-to=origin/main main`). We want to avoid doing anything magic.

## Proposed Plan

1. **Check for Git Repository**: Ensure we are in a valid git repo.
2. **Determine Default Branch**:
   - Run `git rev-parse --abbrev-ref origin/HEAD`.
   - If it fails, sniff for `main` or `master` branches in `origin`.
      - Print an error explaining that `origin/HEAD` is not set.
      - Suggest running `git remote set-head origin <branch>` with the sniffed branch.
      - Exit with a non-zero exit code.
3. **Verify Alignment**:
   - Check if the local branch `<default-branch>` tracks
     `origin/<default-branch>`.
   - If it doesn't align, print a detailed error explaining the mismatch and
     providing the exact command to fix it (e.g., `git branch
     --set-upstream-to=origin/<default-branch> <default-branch>`).
   - Exit with a non-zero exit code.
4. **Checkout**:
   - Run `git checkout <default-branch>`.
5. **Update**:
   - Run `git pull --ff-only`.

## CLI Interface

- Name in pubspec.yaml executables section: `git-gm`
- Arguments: None (usually).

## Testing
We will use `package:test` and `package:test_descriptor` to create tests.
To test scenarios requiring a remote, we can use the "git magic" of cloning
the local repository (e.g., the `scripts` repository itself) on the file
system into a temporary directory. This temporary clone will have `origin`
pointing back to the source repo, making it perfect for testing resolution of
`origin/HEAD` and branch tracking without network access.

Scenarios to test:
1. **Success**: `origin/HEAD` is set, local branch tracks it correctly.
2. **Missing `origin/HEAD`**: Sniffs for `main`/`master`, fails with suggestion.
3. **Alignment Mismatch**: Local branch tracks different remote branch, fails
   with exact instructions on how to configure it.
4. **Dirty Tree / Conflicts**: Verify that `git checkout` default behavior
   handles dirty tree as expected (fails if conflicting).
