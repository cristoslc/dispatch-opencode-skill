#!/usr/bin/env bash
# cleanup-stale.sh — scan for stale locks and orphaned worktrees.
#
# A lock is stale if:
#   1. The PID inside .lock is dead (kill -0 fails), OR
#   2. The lock file mtime exceeds TIMEOUT and the process is still alive
#      (zombie / hung — kill and clean).
#
# Orphaned worktrees: symlinks in .worktrees/ whose target task dir no
# longer exists or whose lockfile PID is dead.
#
# Usage: cleanup-stale.sh [--dry-run] [--abandon] [--timeout <sec>] [<root>]
#   --abandon: call subagent-abandon.sh for each stale/orphaned task
#   --dry-run: report only, do not remove or abandon
#   <root>: project root (default: $PWD)

set -uo pipefail

TIMEOUT=3600
DRY_RUN=0
ABANDON=0
ROOT="$PWD"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --abandon)  ABANDON=1; shift ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    *)         ROOT="$1"; shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ABANDON_SCRIPT="$SCRIPT_DIR/subagent-abandon.sh"

SUBA_DIR="$ROOT/.subagents"
WT_DIR="$ROOT/.worktrees"

NOW=$(date +%s)
CLEANED=0

# Phase 1: scan .subagents/ for stale lock files
if [ -d "$SUBA_DIR" ]; then
  for task_dir in "$SUBA_DIR"/*/; do
    [ -d "$task_dir" ] || continue
    lock="$task_dir/.lock"
    [ -f "$lock" ] || continue

    task_id="$(basename "$task_dir")"

    read -r LOCK_LINE < "$lock" 2>/dev/null || continue
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
    fi

    if [ "$STALE" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "[cleanup-stale] would clean $task_id ($REASON)"
      elif [ "$ABANDON" -eq 1 ] && [ -x "$ABANDON_SCRIPT" ]; then
        "$ABANDON_SCRIPT" --task-id "$task_id" --root "$ROOT"
        echo "[cleanup-stale] abandoned $task_id ($REASON)"
      else
        kill "$LOCK_PID" 2>/dev/null || true
        sleep 1
        kill -0 "$LOCK_PID" 2>/dev/null && kill -9 "$LOCK_PID" 2>/dev/null || true
        rm -rf "$task_dir"
        echo "[cleanup-stale] cleaned $task_id ($REASON)"
      fi
      CLEANED=$((CLEANED + 1))
    fi
  done
fi

# Phase 2: scan .worktrees/ for orphaned symlinks
if [ -d "$WT_DIR" ]; then
  for wt_link in "$WT_DIR"/*; do
    [ -L "$wt_link" ] || continue
    task_id="$(basename "$wt_link")"
    target=$(readlink "$wt_link" 2>/dev/null || echo "")

    ORPHAN=0
    if [ ! -d "$target" ]; then
      ORPHAN=1
      REASON="worktree target does not exist: $target"
    elif [ -f "$SUBA_DIR/$task_id/.lock" ]; then
      read -r LOCK_LINE < "$SUBA_DIR/$task_id/.lock" 2>/dev/null || continue
      LOCK_PID="${LOCK_LINE#PID=}"
      LOCK_PID="${LOCK_PID%%[!0-9]*}"
      if [ -z "$LOCK_PID" ] || ! kill -0 "$LOCK_PID" 2>/dev/null; then
        ORPHAN=1
        REASON="worktree PID $LOCK_PID is dead"
      fi
    fi

    if [ "$ORPHAN" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "[cleanup-stale] would remove orphaned worktree $task_id ($REASON)"
      elif [ "$ABANDON" -eq 1 ] && [ -x "$ABANDON_SCRIPT" ]; then
        "$ABANDON_SCRIPT" --task-id "$task_id" --root "$ROOT"
        echo "[cleanup-stale] abandoned orphaned worktree $task_id"
      else
        rm -f "$wt_link"
        echo "[cleanup-stale] removed orphaned symlink $task_id ($REASON)"
      fi
      CLEANED=$((CLEANED + 1))
    fi
  done
fi

[ "$CLEANED" -eq 0 ] && echo "[cleanup-stale] no stale resources found"

exit 0