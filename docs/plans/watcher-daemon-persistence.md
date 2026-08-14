# Plan: Fix watcher daemon persistence

## Problem

The watcher daemon launched by `watcher.sh start` exits shortly after start. `status` later reports "stopped" and removes the PID file. Background (fire-and-forget) dispatch is unreliable because plans dropped into `.subagents/watch/` are not reliably processed.

## Root cause

In `watcher.sh start`, the daemon runs in a backgrounded subshell:

```bash
(
  echo "$$" > "$PID_FILE"
  while true; do ...; sleep "$INTERVAL"; done
) &
DAEMON_PID=$!
```

Inside a subshell, `$$` expands to the **parent** shell's PID, not the subshell's. The subshell's real PID is `$BASHPID` (or `$!` from the parent). So the PID file records the parent's PID.

The daemon subshell itself survives (it is `&`-backgrounded and detached). But when the parent `watcher.sh start` process exits, `status` reads the PID file, finds the recorded PID (the dead parent) is not alive, reports "stopped", and removes the PID file. The live daemon is orphaned and unreachable — `stop` cannot find it, and `status` cannot report it.

Verified empirically: `$$` in a subshell equals the parent PID; `$BASHPID` equals the subshell PID.

## Changes

### 1. `skills/dispatch-opencode/scripts/watcher.sh` — write the correct PID

In the `start` case, write the subshell's real PID to the PID file using `$BASHPID` instead of `$$`:

```bash
(
  trap 'log "received SIGTERM, exiting"; exit 0' TERM
  echo "$BASHPID" > "$PID_FILE"
  log "daemon started PID=$BASHPID watch-dir=$WATCH_DIR interval=${INTERVAL}s"
  while true; do ...; done
) &
```

`$BASHPID` is the PID of the current bash subshell, which is what `kill` and `kill -0` will target. This makes the PID file accurate, so `status` reports "running" and `stop` can terminate the daemon.

### 2. `skills/dispatch-opencode/scripts/watcher.sh` — robust PID-file write before backgrounding

Write the PID file from the parent using `$!` immediately after backgrounding, so the file exists even if the subshell is slow to start:

```bash
(
  trap 'log "received SIGTERM, exiting"; exit 0' TERM
  while true; do ...; done
) &
DAEMON_PID=$!
echo "$DAEMON_PID" > "$PID_FILE"
```

This removes the race where `start` waits 1s and checks the PID file, which may not exist yet if the subshell has not reached the `echo` line. The parent writes the authoritative PID (`$!` == `$BASHPID` of the subshell) synchronously.

### 3. `skills/dispatch-opencode/scripts/watcher.sh` — restart-tolerant startup

On `start`, if a stale PID file exists but the recorded PID is not alive, remove it and proceed (already handled). Additionally, adopt orphaned task locks: on startup, scan `.subagents/*/.lock` and leave them for `watcher-process.sh` to pick up. This is a defensive improvement; the primary fix is the PID correctness.

### 4. Tests

- New test `skills/dispatch-opencode/tests/test_watcher_persistence.sh` that:
  - Starts the daemon with `--root`.
  - Waits past the parent exit window.
  - Asserts `status` reports `"running"` with the correct PID.
  - Asserts the PID file PID matches the live daemon process.
  - Stops the daemon and asserts `status` reports `"stopped"` and the PID file is removed.
- Update `test_watcher_root.sh` if needed so its start/stop sequence actually verifies persistence (it currently passes because `stop` finds a dead PID and just removes the file).

## Files touched

```
AGENTS.md                                       [MODIFY: add ## Test command declaration]
skills/dispatch-opencode/
  scripts/watcher.sh                          [MODIFY: correct PID write, robust startup]
  tests/test_watcher_persistence.sh            [NEW]
  tests/test_watcher_root.sh                  [MODIFY: verify persistence]
```

## Test command declaration

The project has a test suite (`skills/dispatch-opencode/tests/test_*.sh`) but no `## Test command` in AGENTS.md. The sashay gate (step 7) requires one. Add to AGENTS.md:

```markdown
## Test command

for t in skills/dispatch-opencode/tests/test_*.sh; do bash "$t"; done
```

This matches the documented workflow in `DEVELOPER-WORKFLOWS.md`.

## Out of scope

- The two unrelated failing integration tests (`test_agent_sashay_invocation.sh`, `test_attach_session_visibility.sh`) are not addressed here.
- Full daemonization via `setsid`/`disown` is not required once the PID is correct; the subshell already detaches from the terminal.
