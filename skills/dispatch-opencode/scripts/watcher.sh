#!/usr/bin/env bash
# watcher.sh — daemon entry point for background dispatch.
#
# Supports three subcommands:
#   start   — launch daemon in background
#   stop    — terminate daemon gracefully
#   status  — check if daemon is running
#
# Usage:
#   watcher.sh start [--watch-dir <path>] [--interval <sec>]
#   watcher.sh stop
#   watcher.sh status
#
# The daemon loop:
#   1. Scan watch-dir for *.yaml / *.yml files
#   2. For each, call watcher-process.sh --plan <path> --root <project-root>
#   3. Sleep for interval, repeat
#   4. On SIGTERM, exit cleanly

set -euo pipefail

err() { printf 'watcher: %s\n' "$*" >&2; exit 1; }
log() { printf 'watcher: %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROCESS_SCRIPT="$SCRIPT_DIR/watcher-process.sh"

SUBCOMMAND="${1:-}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
  start)
    WATCH_DIR=""
    INTERVAL=15

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --watch-dir) WATCH_DIR="$2"; shift 2 ;;
        --interval)  INTERVAL="$2"; shift 2 ;;
        *)           err "unknown flag: $1" ;;
      esac
    done

    # Determine project root (where .subagents/ lives)
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

    # Default watch dir
    if [ -z "$WATCH_DIR" ]; then
      WATCH_DIR="$PROJECT_ROOT/.subagents/watch"
    fi

    # Ensure watch directory structure exists
    mkdir -p "$WATCH_DIR/processing"
    mkdir -p "$WATCH_DIR/completed"
    mkdir -p "$WATCH_DIR/failed"
    mkdir -p "$WATCH_DIR/results"

    # Check for existing daemon
    PID_FILE="$PROJECT_ROOT/.subagents/watcher.pid"
    LOG_FILE="$PROJECT_ROOT/.subagents/watcher.log"

    if [ -f "$PID_FILE" ]; then
      OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
      if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        err "daemon already running (PID $OLD_PID) — stop it first"
      fi
      rm -f "$PID_FILE"
    fi

    # Launch daemon in background
    (
      # Trap SIGTERM for clean shutdown
      trap 'log "received SIGTERM, exiting"; exit 0' TERM

      # Write PID file
      echo "$$" > "$PID_FILE"
      log "daemon started PID=$$ watch-dir=$WATCH_DIR interval=${INTERVAL}s"

      while true; do
        # Scan for plan files
        for plan in "$WATCH_DIR"/*.yaml "$WATCH_DIR"/*.yml; do
          [ -f "$plan" ] || continue
          log "found plan: $(basename "$plan")"
          bash "$PROCESS_SCRIPT" --plan "$plan" --root "$PROJECT_ROOT" >> "$LOG_FILE" 2>&1 || {
            log "watcher-process.sh failed for $(basename "$plan")"
          }
        done
        sleep "$INTERVAL"
      done
    ) &
    DAEMON_PID=$!

    # Wait briefly to confirm daemon started and wrote PID
    sleep 1
    if [ -f "$PID_FILE" ]; then
      log "daemon running (PID $(cat "$PID_FILE"))"
    else
      err "daemon failed to start"
    fi
    ;;

  stop)
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    PID_FILE="$PROJECT_ROOT/.subagents/watcher.pid"

    if [ ! -f "$PID_FILE" ]; then
      err "no PID file found at $PID_FILE — daemon not running"
    fi

    DAEMON_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -z "$DAEMON_PID" ]; then
      rm -f "$PID_FILE"
      err "PID file empty — removed"
    fi

    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
      log "daemon PID $DAEMON_PID not running — removing stale PID file"
      rm -f "$PID_FILE"
      exit 0
    fi

    log "stopping daemon (PID $DAEMON_PID)..."
    kill "$DAEMON_PID" 2>/dev/null || true

    # Wait up to 5s for graceful shutdown
    for i in $(seq 1 5); do
      if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        log "daemon stopped"
        rm -f "$PID_FILE"
        exit 0
      fi
      sleep 1
    done

    # Force kill if still running
    log "daemon did not stop gracefully after 5s — sending SIGKILL"
    kill -9 "$DAEMON_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    log "daemon killed"
    ;;

  status)
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    PID_FILE="$PROJECT_ROOT/.subagents/watcher.pid"
    LOG_FILE="$PROJECT_ROOT/.subagents/watcher.log"

    if [ -f "$PID_FILE" ]; then
      DAEMON_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
      if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        # Count active tasks (lock files in .subagents/ excluding watch/)
        ACTIVE_TASKS=0
        ACTIVE_IDS=""
        for lock in "$PROJECT_ROOT/.subagents"/*/.lock; do
          [ -f "$lock" ] || continue
          TASK_ID=$(basename "$(dirname "$lock")")
          ACTIVE_TASKS=$((ACTIVE_TASKS + 1))
          ACTIVE_IDS="${ACTIVE_IDS}${TASK_ID} "
        done
        printf '{"status":"running","pid":%d,"active_tasks":%d,"task_ids":[%s],"log":"%s"}\n' \
          "$DAEMON_PID" "$ACTIVE_TASKS" \
          "$(printf '"%s",' $ACTIVE_IDS | sed 's/,$//')" \
          "$LOG_FILE"
      else
        rm -f "$PID_FILE"
        printf '{"status":"stopped","pid":null,"active_tasks":0,"task_ids":[],"log":"%s"}\n' "$LOG_FILE"
      fi
    else
      printf '{"status":"stopped","pid":null,"active_tasks":0,"task_ids":[],"log":"%s"}\n' "$LOG_FILE"
    fi
    ;;

  *)
    err "usage: watcher.sh {start|stop|status} [options]"
    ;;
esac
