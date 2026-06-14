# Fix dispatch.sh existing-worktree check

## Problem

`scripts/dispatch.sh` line 108 compares the third column of `git worktree list` against a bare branch name, but `git worktree list` wraps branches in square brackets. The existing-worktree check never matches, so the script always falls through to `git worktree add -b <branch>`, which then fails when the branch already exists.

## Fix

Strip brackets from `$3` before comparison in the awk expression on line 108 of `skills/dispatch-opencode/scripts/dispatch.sh`.

## Tasks

- [ ] Apply the one-line awk fix: strip `[` and `]` from `$3` before comparing against `$WORKTREE_BRANCH`
- [ ] Verify the fix compiles (shellcheck)