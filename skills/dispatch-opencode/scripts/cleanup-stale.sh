#!/usr/bin/env bash
# cleanup-stale.sh — scan .subagents/ for stale lock files, clean them up.
#
# A lock is stale if:
#   1. The PID inside .lock is dead (kill -0 fails), OR
#   2. The lock file mtime exceeds TIMEOUT and the process is still alive
#      (zombie / hung — kill and clean).
#
# Usage: cleanup-stale.sh [--dry-run] [--timeout <sec>] [<root>]
#   <root>: project root containing .subagents/ (default: $PWD)
#
# Called in three places:
#   - Pre-dispatch: clean orphaned locks from prior crashes.
#   - Poll loop (parent dispatcher): after each poll, clean this task if stale.
#   - Scheduled / manual: any time.

set -uo pipefail

TIMEOUT=3600
DRY_RUN=0
ROOT="$PWD"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done

SUBA_DIR="$ROOT/.subagents"
[ -d "$SUBA_DIR" ] || exit 0

NOW=$(date +%s)
CLEANED=0

for task_dir in "$SUBA_DIR"/*/; do
  [ -d "$task_dir" ] || continue
  lock="$task_dir/.lock"
  [ -f "$lock" ] || continue

  read -r LOCK_LINE < "$lock"
  LOCK_PID="${LOCK_LINE#PID=}"
  LOCK_PID="${LOCK_PID%%[!0-9]*}"

  PID_DEAD=0
  if [ -z "$LOCK_PID" ] || ! kill -0 "$LOCK_PID" 2>/dev/null; then
    PID_DEAD=1
  fi

  LOCK_MTIME=$(stat -f "%m" "$lock" 2>/dev/null || echo "0")
  STALE=0
  if [ "$PID_DEAD" -eq 1 ]; then
    STALE=1
    REASON="PID $LOCK_PID is dead"
  elif [ "$((NOW - LOCK_MTIME))" -gt "$TIMEOUT" ]; then
    STALE=1
    REASON="lock mtime exceeds ${TIMEOUT}s — hung"
    kill "$LOCK_PID" 2>/dev/null || true
    sleep 1
    kill -0 "$LOCK_PID" 2>/dev/null && kill -9 "$LOCK_PID" 2>/dev/null || true
  fi

  if [ "$STALE" -eq 1 ]; then
    task_id="$(basename "$task_dir")"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[cleanup-stale] would rm -rf $task_dir ($REASON)"
    else
      rm -rf "$task_dir"
      echo "[cleanup-stale] cleaned $task_id ($REASON)"
    fi
    CLEANED=$((CLEANED + 1))
  fi
done

exit 0
