---
title: "Watcher Daemon Script"
artifact: SPEC-001
track: implementable
status: Proposed
author: swain
created: 2026-07-03
last-updated: 2026-07-03
priority-weight: high
type: ""
parent-epic: EPIC-001
parent-initiative: ""
linked-artifacts: []
depends-on-artifacts: []
addresses: []
evidence-pool: ""
source-issue: ""
swain-do: required
---

# Watcher Daemon Script

## Problem Statement

The orchestrator agent currently blocks on `poll-subagent.sh` for every dispatched task. There is no way to fire-and-forget a background task. A persistent watcher daemon is needed to monitor a directory for plan YAMLs, dispatch them, poll for completion, enforce TTL, and clean up.

## Desired Outcomes

Operators and agents can start a watcher daemon that autonomously processes background dispatch plans. The daemon handles the full lifecycle: pickup, dispatch, poll, TTL enforcement, cleanup, result reporting.

## External Behavior

**`watcher.sh`** — the daemon entry point:
- `watcher.sh start [--watch-dir <path>] [--interval <sec>]` — launches the daemon in the background, writes PID to `.subagents/watcher.pid`, logs to `.subagents/watcher.log`
- `watcher.sh stop` — reads PID file, sends TERM, waits for graceful shutdown, removes PID file
- `watcher.sh status` — checks if daemon is running, reports active tasks (scans for `.lock` files in `.subagents/`)

**`watcher-process.sh`** — processes a single plan file:
- Called by the daemon for each new plan YAML found in the watch directory
- Moves the plan to `processing/` (atomic rename)
- Calls `run-plan.sh --plan <plan>` to dispatch
- For each dispatched task, runs a poll loop with TTL enforcement:
  - Checks lockfile — gone means completed
  - Checks events.jsonl for stuck detection (unchanged from poll-subagent.sh)
  - Checks `now - dispatch_time > ttl_sec` — if exceeded, kills and abandons
- On completion: reads `FINAL_OUTPUT.md`, writes result summary to `results/<task-id>.md`, calls `subagent-cleanup.sh`
- On failure/stuck/TTL: writes failure summary to `results/<task-id>.md`, calls `subagent-abandon.sh`
- Moves processed plan to `completed/` or `failed/`

**Directory layout:**
```
.subagents/
  watcher.pid
  watcher.log
  watch/
    plan-001.yaml
    processing/
    completed/
    failed/
    results/
      fix-auth.md
  <task-id>/
    ...
```

## Acceptance Criteria

1. **Start:** `watcher.sh start` launches the daemon, writes PID file, and begins polling the watch directory.
2. **Stop:** `watcher.sh stop` terminates the daemon gracefully and removes the PID file.
3. **Status:** `watcher.sh status` reports "running" with PID when active, "stopped" when not.
4. **Plan pickup:** Dropping a valid plan YAML into the watch directory causes the watcher to process it within one poll interval.
5. **Dispatch:** The watcher calls `run-plan.sh` internally and dispatches all tasks in the plan.
6. **Poll loop:** The watcher polls each dispatched task until completion, stuck, or TTL.
7. **TTL enforcement:** A task with `ttl_sec: 60` is killed and abandoned if it runs longer than 60 seconds.
8. **Result reporting:** On completion, a result summary is written to `results/<task-id>.md`.
9. **Cleanup:** On completion, `subagent-cleanup.sh` is called. On failure/stuck/TTL, `subagent-abandon.sh` is called.
10. **Plan archiving:** Processed plans are moved to `completed/` or `failed/` after processing.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|
| | | |

## Scope & Constraints

- Single watch directory per project root (`.subagents/watch/` by default)
- Polling-based (not inotify/kqueue) — configurable interval, default 15s
- Python 3 is a dependency (used for YAML parsing and file operations)
- The daemon does NOT retry failed tasks — it reports and moves on
- The daemon does NOT adopt orphaned tasks on restart (future enhancement)

## Implementation Approach

1. Create `skills/dispatch-opencode/scripts/watcher.sh` — the daemon entry point with start/stop/status subcommands
2. Create `skills/dispatch-opencode/scripts/watcher-process.sh` — processes a single plan
3. Both scripts follow the existing script conventions (bash, set -euo pipefail, same flag style)
4. The daemon uses a simple polling loop with `sleep $INTERVAL` — no inotify/kqueue
5. TTL enforcement is a simple wall-clock check in the poll loop
6. Result summaries are markdown files with structured frontmatter

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-07-03 | -- | Initial creation |
