---
title: "1-to-N parallelize with orchestrator-owned worktrees"
artifact: PLAN-001
track: implementation
status: Active
author: cristoslc
created: 2026-05-28
last-updated: 2026-05-28
linked-artifacts:
  - ADR-001
depends-on-artifacts:
  - ADR-001
---

# PLAN-001: 1-to-N parallelize with orchestrator-owned worktrees

## Problem

dispatch-opencode dispatches one subagent at a time. To parallelize
across N files, the caller must manually build N task directories, spawn
N background processes, poll N `.lock` files, and collect N results.
There is no worktree lifecycle, so each subagent shares the same working
tree and risks merge conflicts on concurrent edits.

The coordination itself — deciding which tasks are ready, firing them,
polling, reading results, kicking off the next wave — is the AI
orchestrator's job. That is by design. But the **mechanics** of those
operations (spawn a worktree, dispatch a task, poll locks, collect
output, clean up a worktree) should be scripts, not ad-hoc shell
fragments the orchestrator reinvents every time.

## Design constraints

1. **Every dispatch takes an explicit absolute path; verification fails
   closed.** No defaults, no inference. If the path is wrong, the
   script exits non-zero before anything runs.

2. **Every handoff is an on-disk artifact.** Prompt, start script, event
   log, lock file, and final output all live under
   `.subagents/<task-id>/`. The task directory is the source of truth for
   replay and audit.

3. **One template per dispatch kind.** Templates are typed by what the
   dispatch is for (e.g., `single-file-fix`, `headless-spike`), not
   parameterized into a single megatemplate.

4. **Smart orchestrator, dumb subagents.** The orchestrator decides what
   is ready and fires only ready tasks. The skill dispatches what it is
   given. Subagents are single-responsibility and should work on the
   cheapest model that can do the job. The orchestrator continues
   running, polls, and kicks off the next wave. Subagents never
   coordinate with each other or trigger subsequent work.

Constraint 4 means the skill does not implement a dependency graph or
ready-queue. The plan YAML given to `orchestrate.sh` contains only tasks
that are ready to run right now. The orchestrator filters before calling
the skill.

## What changes

### New: `scripts/orchestrate.sh`

1-to-N parallelize dispatcher. Reads a task list, dispatches each via
`dispatch.sh`, polls `.lock` files, and collects results.

Input: a task list (YAML), where each task specifies kind, model, agent,
prompt file, and target.

Output: one `FINAL_OUTPUT.md` per task plus an aggregated result
summary.

The script:

1. Validates each task (kind, model, prompt-file exist).
2. Calls `dispatch.sh` for each task, spawning in the background.
3. Polls all `.lock` files in a single loop.
4. On completion or timeout, records the result per task.
5. When all tasks are done, writes an aggregate summary to
   `.subagents/orchestrate-<id>/results.md`.

The script does not parse dependency edges. The calling orchestrator
already knows which tasks are ready. If the task list includes a task
whose dependency is not yet complete, that is a caller error — the
script dispatches it anyway and the result is undefined.

Usage:

```sh
orchestrate.sh --plan .subagents/plan.yaml [--timeout 600]
```

Plan schema (documented in `references/plan-schema.md`):

```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
  - id: fix-logging
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/fix-logging.md
    target: src/logging.py
```

No `depends` field. The orchestrator only includes tasks whose
dependencies are satisfied. The skill trusts the plan.

### New: worktree lifecycle scripts

Three scripts covering the born / failed / done lifecycle:

**`scripts/worktree-prepare.sh`**

Creates a git worktree under `.worktrees/<label>/`, checks out a new
branch from the current HEAD, and prints the worktree path to stdout.

```sh
worktree-prepare.sh --label fix-auth --root /path/to/repo --branch fix-auth-branch
# stdout: /path/to/repo/.worktrees/fix-auth
```

Steps:

1. Verifies the root is a git repo.
2. Creates `.worktrees/<label>/` via `git worktree add`.
3. Creates and checks out `<branch>` (or uses an existing one).
4. Prints the absolute path.
5. Exits 0 on success, 1 on failure.

**`scripts/worktree-complete.sh`**

Signals a worktree is done. Does not merge — merge semantics are the
orchestrator's decision (commit, PR, squash, etc.). Records completion
state and optionally commits uncommitted changes.

```sh
worktree-complete.sh --label fix-auth --root /path/to/repo [--commit-msg "fix: auth bug"]
```

Steps:

1. Verifies the worktree exists and the branch matches.
2. If `--commit-msg` is given and there are staged/unstaged changes,
   commits them.
3. Writes a `.worktrees/<label>/.complete` marker file with the
   completion timestamp.
4. Prints the worktree path and branch name.
5. Exits 0.

**`scripts/worktree-abandon.sh`**

Cleans up a failed or abandoned worktree. Removes the worktree directory
and deletes the branch.

```sh
worktree-abandon.sh --label fix-auth --root /path/to/repo
```

Steps:

1. Verifies the worktree exists.
2. Removes it via `git worktree remove --force`.
3. Deletes the branch via `git branch -D` (if it exists and is not
   checked out elsewhere).
4. Exits 0.

### New: `scripts/collect-results.sh`

Reads `FINAL_OUTPUT.md` from all tasks in an orchestration run and
produces an aggregated summary. Called by `orchestrate.sh` internally
but also usable standalone.

```sh
collect-results.sh --orchestration-dir .subagents/orchestrate-<id>
# writes .subagents/orchestrate-<id>/results.md
```

### No changes to `scripts/dispatch.sh`

The existing `--cwd` flag already accepts any absolute path, including
worktree paths. `verify-cwd.sh` already checks `--worktree` and
`--worktree-root` flags.

### Changes to `SKILL.md`

1. Add constraint 4 (smart orchestrator, dumb subagents) to the design
   constraints section.
2. Add parallelize section (1-to-N via `orchestrate.sh`).
3. Add worktree lifecycle section (prepare/complete/abandon).
4. Remove "Provision worktrees" from "What this skill does NOT do."
5. Add all new scripts to the scripts reference.
6. Add note: "Only include tasks whose dependencies are satisfied. The
   skill dispatches all tasks in the plan without dependency ordering."

### Changes to `references/examples.md`

1. Add parallelize example using `orchestrate.sh` with a plan file.
2. Add worktree lifecycle example (prepare, dispatch, complete/abandon).

### New: `references/plan-schema.md`

Documents the task list YAML schema that `orchestrate.sh` accepts.

### New: tests

- `tests/test_orchestrate_parallelize.sh` — dispatches 2-3 tasks via
  `orchestrate.sh`, verifies `.lock` lifecycle, result collection, and
  aggregate summary.
- `tests/test_worktree_lifecycle.sh` — prepares a worktree, verifies
  branch and path, completes it with a commit, then tests abandon on a
  second worktree.

## What does not change

- Dispatch target is always `opencode run`. The orchestrator's identity
  (Claude Code, Codex, opencode) does not change the subagent
  invocation. `templates/runtimes/` adapters handle how the orchestrator
  calls the skill, not how the skill invokes the subagent.
- No dependency graph in scripts. The AI orchestrator knows which tasks
  are ready. The plan YAML has no `depends` field.
- No result injection into downstream prompts. The orchestrator reads
  `FINAL_OUTPUT.md` and constructs the next prompt itself.
- Template structure unchanged. `templates/cli/` stays as-is.

## File manifest

| File | Action | Purpose |
|------|--------|---------|
| `scripts/orchestrate.sh` | new | 1-to-N parallelize dispatcher |
| `scripts/worktree-prepare.sh` | new | Create worktree, return path |
| `scripts/worktree-complete.sh` | new | Signal worktree done |
| `scripts/worktree-abandon.sh` | new | Clean up abandoned worktree |
| `scripts/collect-results.sh` | new | Aggregate results across tasks |
| `references/plan-schema.md` | new | Task list YAML schema |
| `SKILL.md` | modify | Constraint 4, parallelize, worktree lifecycle |
| `references/examples.md` | modify | Parallelize and worktree examples |
| `tests/test_orchestrate_parallelize.sh` | new | Orchestrator integration test |
| `tests/test_worktree_lifecycle.sh` | new | Worktree lifecycle integration test |

## Implementation order

1. `scripts/worktree-prepare.sh` + test — standalone, no dependencies on
   other new scripts.
2. `scripts/worktree-complete.sh` + `scripts/worktree-abandon.sh` + test
   — completes the worktree lifecycle.
3. `references/plan-schema.md` — defines the contract for orchestrate.
4. `scripts/collect-results.sh` — standalone, needed by orchestrate.
5. `scripts/orchestrate.sh` + test — depends on `dispatch.sh` and
   `collect-results.sh`.
6. SKILL.md + examples.md updates — after all scripts are tested.

Each step is independently testable. The skill remains functional after
each step.