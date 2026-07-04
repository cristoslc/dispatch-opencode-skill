# Watcher Daemon: Foreground/Background Dispatch Mode

Date: 2026-07-03

## The problem

The current dispatch model is **orchestrator-synchronous**: the agent writes a plan, calls `run-plan.sh`, gets back lockfile paths, then calls `poll-subagent.sh` and blocks until each task completes. The agent is the orchestrator and it stays in the loop for the entire task lifecycle.

This works fine when the agent has nothing better to do. But it breaks when:

- The agent wants to fire off a task and move on to other work (planning the next task, answering the operator, etc.)
- The agent wants to dispatch a long-running task (dependency upgrade, large refactor) without blocking its own session
- The operator wants to background work from a terminal session and close it, letting the work complete autonomously

## What already exists

The dispatch pipeline already backgrounds the subagent process (`dispatch.sh` line 234: `bash "$TASK_DIR/start-subagent.sh" > ... &`). The subagent runs in a background process. But the *orchestrator* (the calling agent) still blocks on `poll-subagent.sh` — it's the orchestrator's polling loop that's synchronous, not the subagent execution.

The `--attach` mode (when `OPENCODE_SERVER_URL` is set) means the subagent connects to a persistent server daemon. The server daemon is already a background process. But there's no daemon that *watches for new work* — the server just accepts incoming `--attach` connections.

## The insight

The orchestrator's job can be decomposed into two roles:

1. **Planner** — decides what to do, writes the plan, creates the prompt
2. **Watcher** — monitors dispatched tasks, handles completion/cleanup

Currently the agent plays both roles, sequentially. The proposal is to split them: the agent plays Planner, and a persistent **watcher daemon** plays Watcher.

The agent just needs to decide: "Do I want to wait for this (foreground) or fire-and-forget (background)?"

## Proposal: watcher daemon

### What it is

A persistent background process (`opencode-watcher`) that:

1. Watches a directory (`.subagents/watch/` or a configurable path) for new plan YAML files
2. When a plan appears, it calls `run-plan.sh` to dispatch
3. It polls each dispatched task via `poll-subagent.sh`
4. On completion, it reads `FINAL_OUTPUT.md` and calls `subagent-cleanup.sh`
5. On failure/stuck/timeout, it calls `subagent-abandon.sh`
6. It writes a result summary back to the watched directory (or a results directory)

### Start/stop

```
opencode-watcher start [--watch-dir <path>] [--interval <sec>]
opencode-watcher stop
opencode-watcher status
```

- `start` — launches the watcher daemon in the background, writes a PID file
- `stop` — reads the PID file, sends TERM, cleans up
- `status` — checks if the watcher is running, reports active tasks

### How the agent uses it

The agent writes a plan YAML to the watched directory. The watcher picks it up.

**Foreground mode** (current behavior, default):
```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    mode: foreground    # explicit, or default
```

The agent calls `run-plan.sh --plan plan.yaml` directly. The agent blocks on `poll-subagent.sh`. Same as today.

**Background mode** (new):
```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    mode: background    # explicit
```

The agent writes the plan to `.subagents/watch/plan.yaml`. The watcher picks it up. The agent is free to continue. The agent can check `.subagents/watch/results/<task-id>.md` later.

### How the agent picks

The SKILL.md would tell the agent:

> By default, tasks run in **foreground** mode — the agent blocks until completion. Set `mode: background` in the plan YAML to fire-and-forget. The watcher daemon must be running for background mode. If it's not running, `run-plan.sh` falls back to foreground with a warning.

The agent just adds one field. The script does the rest.

### What the watcher does with a plan

1. Detects new `.yaml`/`.yml` files in the watch directory
2. Moves them to a `processing/` subdirectory (atomic rename to avoid double-processing)
3. Calls `run-plan.sh --plan <plan>` (which calls `dispatch.sh` internally)
4. For each dispatched task, calls `poll-subagent.sh` with generous defaults (longer timeout for background tasks)
5. On completion: reads `FINAL_OUTPUT.md`, writes a result summary to `results/<task-id>.md`, calls `subagent-cleanup.sh`
6. On failure: writes a failure summary to `results/<task-id>.md`, calls `subagent-abandon.sh`
7. Moves the processed plan to `completed/` or `failed/`

### TTL: background agents must not run forever

Background agents are fire-and-forget, which means nothing is watching them after the watcher dispatches them. If a subagent enters an infinite loop, gets stuck on a permission prompt, or just takes way longer than expected, it spins until the watcher's `poll-subagent.sh` times out — and the default timeout is only a few minutes.

For background tasks, the watcher needs a **hard TTL** (time-to-live) per task. When the TTL expires, the watcher kills the subagent (TERM then KILL) and marks the task as failed/abandoned. This is distinct from `poll-subagent.sh`'s stuck detection (which detects stalled progress) and timeout (which detects max polls reached). TTL is a **wall-clock deadline** — regardless of whether the subagent is making progress, it gets killed at the deadline.

**Plan schema** — new optional `ttl_sec` field:
```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    mode: background
    ttl_sec: 3600       # kill after 1 hour wall-clock
```

- `ttl_sec` is only meaningful in `mode: background`. In foreground mode, the agent's own polling loop handles timeout.
- If `ttl_sec` is not set, the watcher uses a default (e.g., 1800 = 30 minutes).
- The watcher records the dispatch timestamp when it calls `run-plan.sh`. On each poll iteration, it checks: `now - dispatch_time > ttl_sec`. If yes, it calls `subagent-abandon.sh` and writes a "TTL exceeded" result.

**How the watcher enforces TTL:**

The watcher's poll loop for each task becomes:
1. Check lockfile — gone means completed
2. Check events.jsonl for stuck detection (existing logic)
3. Check `now - dispatch_time > ttl_sec` — if exceeded, kill and abandon
4. Sleep and repeat

This is a small addition to the watcher's poll loop. The existing `poll-subagent.sh` script doesn't need to change — the watcher wraps it with its own TTL check, or the watcher runs its own poll loop that includes TTL enforcement instead of calling `poll-subagent.sh` directly.

**Why TTL matters for background agents:**

- **No one is watching.** The agent that dispatched the task has moved on. If the subagent hangs, nobody notices until the operator checks.
- **Cost control.** Background agents consume model API calls. A runaway agent can burn through quota.
- **Resource cleanup.** Even with `subagent-abandon.sh`, a zombie subagent that's been running for hours may have left the worktree in an inconsistent state. Better to kill early.
- **Operator trust.** If the operator knows background agents have a hard deadline, they can fire-and-forget without worrying about runaway processes.

**TTL vs. existing timeout mechanisms:**

| Mechanism | Scope | Trigger | Action |
|-----------|-------|---------|--------|
| `poll-subagent.sh` timeout | Per-poll-loop | Max polls reached, lockfile still present | Exit 3 (caller handles) |
| `poll-subagent.sh` stuck | Per-poll-loop | Events.jsonl unchanged past stale threshold | Exit 2 (caller handles) |
| Template `timeout(1)` | Per-subagent | 600s wall-clock (hardcoded in templates) | Kills `opencode run` process |
| **TTL (proposed)** | Per-task, watcher-enforced | `now - dispatch_time > ttl_sec` | Watcher calls `subagent-abandon.sh` |

The template's `timeout(1)` at 600s is a safety net for the subagent process itself. TTL is a higher-level policy enforced by the watcher. They serve different purposes: the template timeout prevents a single `opencode run` from running forever; TTL prevents the entire background task lifecycle from exceeding a deadline (which could span multiple `opencode run` invocations if the watcher supports retry, or just be a longer grace period for complex tasks).

### Directory layout

```
.subagents/
  watch/              ← agent drops plans here
    plan-001.yaml
    processing/       ← watcher moves plans here while working
    completed/        ← watcher moves plans here when done
    failed/           ← watcher moves plans here on failure
    results/          ← watcher writes result summaries here
      fix-auth.md
      refactor-api.md
  <task-id>/          ← existing task directories (created by dispatch.sh)
    ...
```

### What this changes in the skill

**Plan schema** — new optional `mode` field:
```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    mode: background   # "foreground" (default) or "background"
```

**New scripts:**
- `watcher.sh` — the daemon itself (start/stop/status, watch loop)
- `watcher-process.sh` — processes a single plan (called by watcher.sh for each new plan)

**Modified scripts:**
- `run-plan.sh` — when `mode: background`, writes the plan to the watch directory instead of dispatching directly. Or: `run-plan.sh` stays the same, and the agent writes to the watch directory directly. I think the cleaner approach is: the agent writes the plan to the watch directory, and the watcher picks it up. No change to `run-plan.sh` needed for background mode.

Actually, even cleaner: the agent writes the plan YAML to `.subagents/watch/` and the watcher picks it up. The agent doesn't call `run-plan.sh` at all for background tasks. The watcher calls `run-plan.sh` internally.

**SKILL.md updates:**
- New workflow: "Background dispatch" — write plan to watch directory, continue working
- New section: "Watcher daemon" — how to start/stop/check status
- Updated plan schema with `mode` field

### What this does NOT change

- The existing foreground dispatch flow (agent calls `run-plan.sh`, polls, cleans up) is unchanged
- The existing templates (single-file-fix, multi-file-fix, headless-spike) are unchanged
- The existing scripts (dispatch.sh, poll-subagent.sh, subagent-cleanup.sh, subagent-abandon.sh) are unchanged
- The worktree isolation model is unchanged

### Open questions

1. **Should the watcher be a shell script or a small Python daemon?** Shell is simpler for the existing codebase (all scripts are bash). But a Python daemon would handle file watching (inotify/kqueue) more cleanly than a polling loop. Python is already a dependency (used in template rendering).

2. **How does the agent discover results?** The agent can check `.subagents/watch/results/<task-id>.md` for a result summary. Or the watcher could write to a known location. The simplest approach: the agent knows the task ID and checks the results directory.

3. **What about worktree tasks in background mode?** Worktree creation is fine. But cleanup is different — the watcher handles it. The watcher calls `subagent-cleanup.sh` which removes the worktree. If the operator wants to inspect the worktree before cleanup, they need to set a flag or the watcher needs a "keep worktree" option.

4. **Should the watcher support multiple watch directories?** Probably not for v1. One watch directory per project root.

5. **What about the `--attach` mode interaction?** If `OPENCODE_SERVER_URL` is set, the subagent connects to the server. The watcher doesn't need to know about this — it's handled by the template. The watcher just calls `run-plan.sh` which calls `dispatch.sh` which renders the template.

6. **PID file location?** `.subagents/watcher.pid` — keeps it inside the project's `.subagents/` directory.

7. **Logging?** The watcher should log to `.subagents/watcher.log` for debugging.

8. **What if the watcher crashes mid-task?** The task continues running (it's a separate process). On restart, the watcher should scan for orphaned `.lock` files and adopt them. This is similar to `cleanup-stale.sh` but in reverse — adopt instead of abandon.

## Relationship to existing patterns

The watcher daemon is the natural complement to the existing `opencode serve` daemon:
- `opencode serve` — persistent HTTP server that accepts `--attach` connections
- `opencode-watcher` — persistent plan watcher that dispatches and manages tasks

Together they form a complete background processing system: the server provides the runtime, the watcher provides the work queue.

## Summary

| Aspect | Foreground (current) | Background (new) |
|--------|---------------------|-------------------|
| Agent blocks? | Yes (on poll-subagent) | No |
| Watcher needed? | No | Yes |
| Plan goes to | `run-plan.sh` directly | `.subagents/watch/` |
| Result retrieval | Immediate (FINAL_OUTPUT.md) | Deferred (results dir) |
| Cleanup | Agent calls cleanup | Watcher calls cleanup |
| Use case | Quick tasks, sequential work | Long tasks, fire-and-forget |
