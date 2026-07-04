# SPEC-003: SKILL.md Updates for Background Dispatch Workflow

Update `skills/dispatch-opencode/SKILL.md` to document the new background dispatch workflow, watcher daemon, and updated plan schema.

## Changes needed

### 1. Add "Background dispatch" workflow

After the existing "Workflow 1: Single task" section, add a new workflow:

### Workflow 3: Background dispatch (fire-and-forget)

1. Ensure the watcher daemon is running (`watcher.sh status`).
2. Write a plan YAML with `mode: background` (and optionally `ttl_sec`).
3. Write the plan to `.subagents/watch/<plan-name>.yaml`.
4. Continue working — the watcher picks it up, dispatches, polls, and cleans up.
5. Check results later at `.subagents/watch/results/<task-id>.md`.

### 2. Add "Watcher daemon" section

After the "Script inventory" table, add:

## Watcher daemon

The watcher daemon (`watcher.sh`) is a persistent background process that monitors a directory for plan YAMLs and processes them autonomously.

```
watcher.sh start [--watch-dir <path>] [--interval <sec>]
watcher.sh stop
watcher.sh status
```

- `start` — launches daemon, writes PID to `.subagents/watcher.pid`, logs to `.subagents/watcher.log`
- `stop` — terminates daemon gracefully
- `status` — returns JSON with running status, PID, active task count

The daemon must be running for background dispatch. If it's not running, write plans to `.subagents/watch/` anyway — they'll be processed when the daemon starts.

### 3. Update plan schema table

Add `mode` and `ttl_sec` to the plan schema table in the "Plan schema" section:

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Task identifier |
| `kind` | yes | Dispatch kind |
| `model` | yes | Provider/model string |
| `prompt` | yes | Path to prompt file |
| `target` | for single-file-fix | Target file path |
| `worktree` | no | Branch name for worktree |
| `agent` | no | Agent type (defaults per kind) |
| `mode` | no | `foreground` (default) or `background` |
| `ttl_sec` | no | Wall-clock deadline in seconds (background only, default 1800) |

### 4. Update script inventory

Add to the script inventory table:

| `watcher.sh` | yes | Daemon entry point — start/stop/status |
| `watcher-process.sh` | no (internal) | Process a single plan from the watch directory |

### 5. Update directory structure

Add the watch directory layout to the directory structure section:

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

### 6. Update "When to use" section

Add to the "When to use" list:
- The agent wants to fire-and-forget a long-running task and continue working
- The operator wants to background work from a terminal session and close it

## File to modify

- `skills/dispatch-opencode/SKILL.md`

## Acceptance criteria

1. SKILL.md has a "Background dispatch" workflow section
2. SKILL.md has a "Watcher daemon" section with start/stop/status commands
3. SKILL.md plan schema table includes `mode` and `ttl_sec` fields
4. SKILL.md script inventory includes `watcher.sh` and `watcher-process.sh`
5. SKILL.md directory structure includes `.subagents/watch/` layout
6. The "When to use" section mentions background dispatch
