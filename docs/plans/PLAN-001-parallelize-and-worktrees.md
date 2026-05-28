---
title: "1-to-N parallelize with agent-owned lifecycle"
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

# PLAN-001: 1-to-N parallelize with agent-owned lifecycle

## Problem

dispatch-opencode dispatches one subagent at a time. To parallelize
across N files, the caller must manually build N task directories, spawn
N background processes, poll N `.lock` files, and collect N results.
There is no worktree lifecycle, so each subagent shares the same working
tree and risks merge conflicts on concurrent edits.

The coordination — deciding which tasks are ready, polling for results,
deciding what to do with them — is the agent's job. But the **mechanics**
(validate a plan, prepare a worktree, dispatch a task, clean up
artifacts) should be scripts, not ad-hoc shell the agent reinvents each
time. And those mechanics need a **contract** so the agent can trust
that a declared intent (plan YAML) is enforced before anything runs.

## Architecture

### Script inventory

| Script | Agent-facing | Owns |
|--------|-------------|------|
| `run-plan.sh` | yes | Plan validation, worktree preparation, dispatching, structured output |
| `dispatch.sh` | no (internal) | Single-task prepare, spawn, confirm .lock appeared |
| `subagent-cleanup.sh` | yes | Remove completed task artifacts + worktree |
| `subagent-abandon.sh` | yes | Kill PID, force-remove failed task + worktree |
| `cleanup-stale.sh` | yes | Scan for stale locks and orphaned worktrees |

`collect-results.sh` is a convenience the agent may call but is not
part of the core lifecycle.

### Agent workflows

**Workflow 1: Single task.** Agent writes a 1-task plan, calls run-plan.sh,
gets back a lockfile path, polls it, reads FINAL_OUTPUT.md, calls
subagent-cleanup.sh or subagent-abandon.sh.

**Workflow 2: Parallelize N tasks.** Agent writes an N-task plan, calls
run-plan.sh, gets back N lockfile paths, polls them on a 15-second
interval, reads each FINAL_OUTPUT.md as tasks complete, calls cleanup or
abandon per task.

**Workflow 3: Stale resource recovery.** Agent (or a scheduled job) calls
cleanup-stale.sh after a crash or long idle period. Finds orphaned
locks and worktrees, reports them, optionally cleans them up.

**Workflow 4: Result aggregation.** After all tasks complete, agent calls
collect-results.sh for a combined summary. Optional — the agent can
read each FINAL_OUTPUT.md directly.

### Lifecycle phases

Every task goes through these phases. Each phase has an agent action and
a supporting script.

**1. Intent.** Agent writes a plan YAML declaring what it wants done.
Agent action only. No script involvement.

**2. Validation and dispatch.** Agent calls `run-plan.sh --plan plan.yaml`.
The script validates the plan schema, required fields, and file
existence. For tasks declaring a worktree, it calls worktree preparation
internally. For each valid task, it calls dispatch.sh (internal). Failed
worktree preparation skips that task (reported as skipped, not error).
The script returns structured output (JSON) to stdout with lockfile
paths, PIDs, task dirs, and per-task status (dispatched or skipped).
The script exits immediately — it does not poll or wait.

**3. Monitor.** Agent polls lockfiles on its own interval (~15s). Two
checks per lockfile:
- Lockfile gone → task completed. Read FINAL_OUTPUT.md.
- PID from lockfile is dead → task stalled. Decide to abandon.

Agent action only. No script involvement during monitoring. The agent
owns the poll loop.

**4. Consume.** Agent reads FINAL_OUTPUT.md for each completed task.
Agent merges work via normal git operations (merge, PR, squash — the
agent decides). No script involvement.

**5. Cleanup.** Agent calls one of two scripts depending on the task
outcome:
- `subagent-cleanup.sh` — task completed successfully. Removes .lock,
  removes symlink in .worktrees/, git worktree removes the real tree
  under .subagents/, removes .subagents/ task dir.
- `subagent-abandon.sh` — task failed or is no longer needed. Kills
  the PID (TERM then KILL), removes .lock, removes symlink in
  .worktrees/, git worktree remove --force + git branch -D, removes
  .subagents/ task dir.

### Directory structure

```
<project-root>/
  .subagents/
    <task-id>/
      prompt.md
      start-subagent.sh
      .lock                ← exists while subagent runs
      events.jsonl
      FINAL_OUTPUT.md
      worktree/            ← real git worktree (if task declared one)
  .worktrees/
    <task-id>             ← symlink → ../.subagents/<task-id>/worktree/
```

`.subagents/` is gitignored. The real worktree lives inside the task
directory so its lifecycle is bound to the task — remove the task dir
and the worktree goes with it (after git worktree remove). The symlink
in `.worktrees/` lets other tooling (swain, etc.) discover active
worktrees without scanning `.subagents/`.

`.worktrees/` is also gitignored (already in most project .gitignore
files).

### Structured output from run-plan.sh

The agent needs machine-readable output to build its poll loop.
run-plan.sh writes JSON to stdout:

```json
{
  "plan_id": "20260528T151600Z",
  "tasks": [
    {
      "id": "fix-auth",
      "lockfile": "/abs/path/.subagents/fix-auth/.lock",
      "task_dir": "/abs/path/.subagents/fix-auth",
      "pid": 48912,
      "worktree": "/abs/path/.worktrees/fix-auth",
      "status": "dispatched"
    },
    {
      "id": "fix-logging",
      "lockfile": "/abs/path/.subagents/fix-logging/.lock",
      "task_dir": "/abs/path/.subagents/fix-logging",
      "pid": 48913,
      "worktree": null,
      "status": "dispatched"
    },
    {
      "id": "fix-api",
      "status": "skipped",
      "reason": "worktree creation failed: branch already exists"
    }
  ]
}
```

The agent parses this, extracts lockfile paths and PIDs, and enters
its poll loop.

### Dispatch.sh internal interface

dispatch.sh is no longer agent-facing. It is called only by run-plan.sh.

```
dispatch.sh --root <project-root> --cwd <worktree-or-project-dir> \
  --kind single-file-fix --model ollama-cloud/glm-5.1 --agent build \
  --prompt-file prompts/fix-auth.md --target src/auth.py \
  --task-id fix-auth
```

Key change from current: `--root` and `--cwd` are separate. `--root` is
where `.subagents/` lives. `--cwd` is where opencode runs (could be a
worktree path). `--task-id` comes from the plan (stable, predictable).

dispatch.sh:
1. Creates `.subagents/<task-id>/` under `--root`.
2. Copies prompt, renders start-subagent.sh.
3. If task has a worktree, creates the symlink in `.worktrees/`.
4. Spawns start-subagent.sh in the background.
5. Waits up to 7.5s for .lock to appear (spawn confirmation).
6. Writes task metadata (lockfile path, PID, task dir) to stdout as
   JSON and exits 0.

dispatch.sh does NOT poll. It does NOT read FINAL_OUTPUT.md. It does
NOT detect stalls. It confirms the spawn and returns.

### Plan schema

```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    worktree: fix-auth-branch     # optional. If set, run-plan.sh
                                  # creates .subagents/fix-auth/worktree/
                                  # on this branch.
```

Fields: `id` (required), `kind` (required), `model` (required),
`prompt` (required), `target` (required for single-file-fix),
`worktree` (optional, branch name for worktree creation),
`agent` (optional, defaults per kind), `timeout` (optional, agent-side
concern — not in the contract).

No `depends` field. The agent writes only tasks that are ready to run
right now.

### subagent-cleanup.sh

```
subagent-cleanup.sh --task-id <id> --root <project-root>
```

Steps:
1. Remove `.subagents/<task-id>/.lock` if present.
2. Remove symlink `.worktrees/<task-id>/` if present.
3. `git worktree remove .subagents/<task-id>/worktree/` if the worktree
   directory exists (no --force — should be clean after merge).
4. Remove `.subagents/<task-id>/` directory.
5. Exit 0.

### subagent-abandon.sh

```
subagent-abandon.sh --task-id <id> --root <project-root>
```

Steps:
1. Read PID from `.subagents/<task-id>/.lock`.
2. If PID is alive: TERM, wait 2s, KILL if still alive.
3. Remove `.subagents/<task-id>/.lock`.
4. Remove symlink `.worktrees/<task-id>/` if present.
5. `git worktree remove --force .subagents/<task-id>/worktree/` if
   the worktree directory exists.
6. Delete the branch (if it exists and is not checked out elsewhere).
7. Remove `.subagents/<task-id>/` directory.
8. Exit 0.

### cleanup-stale.sh (enhanced)

Current: scans `.subagents/` for stale lock files, removes them.

Enhanced: also scans for orphaned worktrees (symlinks in `.worktrees/`
whose target task dir no longer exists or whose lockfile PID is dead).
Optionally calls subagent-abandon.sh for each orphaned task.

```
cleanup-stale.sh [--abandon] [<root>]
```

- Without `--abandon`: reports stale locks and orphaned worktrees.
- With `--abandon`: calls subagent-abandon.sh for each found task.

### start-subagent.sh (rendered template)

Writes `.lock` with PID, runs `opencode run --dir <cwd>`, captures
events.jsonl and writes FINAL_OUTPUT.md, removes `.lock`. Runs inside
`.subagents/<task-id>/` so artifacts land in `.subagents/` on the
project root, not in the worktree. opencode edits files in `--dir`
(the worktree), but writes dispatch artifacts in its working directory
(the task dir).

### What about archive?

Dropped for now. If use cases emerge (audit trail beyond the agent's
current context, compliance, post-mortem), explore later.

## What changes from current state

### New scripts

| Script | Purpose |
|--------|---------|
| `run-plan.sh` | Agent entry point: validate plan, prepare worktrees, dispatch, return lockfile list |
| `subagent-cleanup.sh` | Remove completed task + worktree |
| `subagent-abandon.sh` | Kill + force-remove failed task + worktree |

### Modified scripts

| Script | Change |
|--------|--------|
| `dispatch.sh` | Internal-only. Add `--root`, `--task-id` flags. Remove internal poll loop. Return JSON on stdout. No longer agent-facing. |
| `cleanup-stale.sh` | Add worktree scanning, `--abandon` flag, integration with subagent-abandon.sh |

### Removed scripts

| Script | Replace with |
|--------|-------------|
| `worktree-prepare.sh` | Internal to run-plan.sh (or dispatch.sh) |
| `worktree-complete.sh` | `subagent-cleanup.sh` |
| `worktree-abandon.sh` | `subagent-abandon.sh` |

The worktree lifecycle scripts from the earlier draft are folded into
the task lifecycle. Worktree creation is internal to run-plan.sh /
dispatch.sh. Worktree teardown is part of cleanup or abandon.

### Existing scripts that don't change

| Script | Notes |
|--------|-------|
| `verify-cwd.sh` | Still called by dispatch.sh |
| `validate-run.sh` | Still called after dispatch for post-hoc validation |

### Template changes

`start-subagent.sh` rendered templates need to write `.lock` and
`FINAL_OUTPUT.md` in the task dir (project root's `.subagents/`), not
in the cwd. Currently they `cd` to cwd and write there — this needs to
change so the cwd is only the opencode `--dir` argument, and the task
dir is where artifacts go.

### SKILL.md changes

1. Add constraint 4 (smart orchestrator, dumb subagents).
2. Replace "Parallel fan-out" section with "Run plan" section.
3. Replace "Provision worktrees" in "What this skill does NOT do" with
   lifecycle section documenting cleanup and abandon workflows.
4. Update required arguments table to reflect run-plan.sh as primary
   entry point.
5. Update dispatch flow chart to reflect the new agent-owned lifecycle.

### references/examples.md changes

1. Replace parallel fan-out shell snippet with run-plan.sh example.
2. Add lifecycle examples: cleanup, abandon, stale recovery.

## Implementation order

1. **dispatch.sh refactor** — add `--root`, `--task-id` flags. Remove
   poll loop. Return JSON on stdout. Change start-subagent.sh templates
   to write artifacts in task dir, not cwd.
2. **subagent-cleanup.sh** — standalone, no dependencies on run-plan.sh.
3. **subagent-abandon.sh** — standalone, no dependencies on run-plan.sh.
4. **cleanup-stale.sh enhancement** — add worktree scanning, --abandon.
5. **run-plan.sh** — depends on refactored dispatch.sh.
6. **SKILL.md + examples.md** — after all scripts are tested.

Each step is independently testable. The skill remains functional after
each step.