# Branch Names with Slashes: Safety Audit

## The Bug

An agent created a feature branch `feat/abc`. The branch validation in `dispatch.sh` rejected it because the whitelist `[A-Za-z0-9_.-]` does not include `/`.

## Impact

- `dispatch.sh:71` — rejects any branch name containing `/` with "unsafe worktree branch"
- `verify-cwd.sh:57` — same whitelist on worktree labels, same rejection

This is overly restrictive. Git branch names with `/` (hierarchical names like `feat/abc`, `fix/123`, `release/v2`) are standard practice.

## Safety Analysis

Every site that consumes a branch name was audited:

| Location | Usage | Safe with `/`? |
|---|---|---|
| `dispatch.sh:71` | Validation whitelist | Needs `/` added |
| `dispatch.sh:108` | `awk -v b="$BRANCH"` string compare | Yes — quoted awk var |
| `dispatch.sh:115` | `git worktree add -b "$BRANCH"` | Yes — git supports hierarchical refs |
| `dispatch.sh:247` | `[ -n "$BRANCH" ]` | Yes — just emptiness check |
| `subagent-abandon.sh:63` | `git branch --show-current` | Yes — reads actual ref |
| `subagent-abandon.sh:68` | `git branch -D "$BRANCH"` | Yes — quoted, git supports `/` |
| `verify-cwd.sh:47` | `[ "$A" != "$B" ]` | Yes — quoted string compare |
| `verify-cwd.sh:79` | Glob suffix `*"/$LABEL"` | Yes — glob handles `/` naturally |

No unquoted expansion, no path construction from branch name, no injection risk. The `/` character is safe everywhere the branch name flows.

## Fix

Add `/` to the whitelist in both `dispatch.sh` and `verify-cwd.sh`:

```
A-Za-z0-9_.-  →  A-Za-z0-9_./-
```
