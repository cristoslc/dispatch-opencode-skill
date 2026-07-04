# SPEC-001: Watcher Daemon Script

Implement the watcher daemon for background dispatch. Create two scripts in `skills/dispatch-opencode/scripts/`:

## 1. `watcher.sh` — Daemon entry point

Supports three subcommands:

- `watcher.sh start [--watch-dir <path>] [--interval <sec>]` — launches daemon in background, writes PID to `.subagents/watcher.pid`, logs to `.subagents/watcher.log`. Default watch-dir is `<project-root>/.subagents/watch/`. Default interval is 15s.
- `watcher.sh stop` — reads PID file, sends TERM, waits up to 5s, removes PID file.
- `watcher.sh status` — checks if daemon is running, reports active tasks (scans for `.lock` files in `.subagents/`).

The daemon loop:
1. Scan watch-dir for `*.yaml`/`*.yml` files
2. For each, call `watcher-process.sh --plan <path> --root <project-root>`
3. Sleep for interval, repeat
4. On SIGTERM, exit cleanly

## 2. `watcher-process.sh` — Process a single plan

Called by the daemon for each new plan YAML.

Usage: `watcher-process.sh --plan <plan-yaml> --root <project-root>`

Steps:
1. Move plan to `processing/` subdirectory (atomic rename via `mv`)
2. Call `run-plan.sh --plan <plan>` to dispatch
3. Parse JSON output from run-plan.sh to get task IDs, lockfile paths, PIDs
4. For each dispatched task, run a poll loop:
   - Check lockfile — gone means completed
   - Check events.jsonl for stuck detection (same logic as poll-subagent.sh)
   - Check `now - dispatch_time > ttl_sec` — if exceeded, kill and abandon
   - Sleep interval (default 15s), repeat up to max-polls (default 120 = 30 min)
5. On completion: read FINAL_OUTPUT.md, write result summary to `results/<task-id>.md`, call `subagent-cleanup.sh`
6. On failure/stuck/TTL: write failure summary to `results/<task-id>.md`, call `subagent-abandon.sh`
7. Move processed plan to `completed/` or `failed/`

## Directory layout to create:

```
.subagents/
  watcher.pid
  watcher.log
  watch/
    processing/
    completed/
    failed/
    results/
```

Create these directories inside the project root when the watcher starts (if they don't exist).

## Script conventions

Follow the existing script style in `skills/dispatch-opencode/scripts/`:
- `set -euo pipefail`
- Same flag parsing style (`--flag) "$2"; shift 2`)
- Same error handling (`err() { ... }`)
- All output to stderr except structured JSON on stdout
- Use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` to find sibling scripts

## Files to create

- `skills/dispatch-opencode/scripts/watcher.sh`
- `skills/dispatch-opencode/scripts/watcher-process.sh`

## Acceptance criteria

1. `watcher.sh start` launches daemon, writes PID file, begins polling
2. `watcher.sh stop` terminates daemon gracefully, removes PID file
3. `watcher.sh status` reports running/stopped with PID
4. Dropping a valid plan YAML into watch-dir causes processing within one interval
5. Watcher calls run-plan.sh internally and dispatches all tasks
6. Watcher polls each task until completion, stuck, or TTL
7. On completion: result summary written, subagent-cleanup.sh called
8. On failure: failure summary written, subagent-abandon.sh called
9. Processed plans moved to completed/ or failed/
10. TTL enforcement: task with ttl_sec: 60 is killed after 60s
