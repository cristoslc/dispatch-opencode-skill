#!/usr/bin/env bash
# subagent-abandon.sh — kill and force-remove a failed or abandoned task.
#
# Terminates the subagent process (TERM then KILL), removes .lock,
# force-removes the worktree and branch, and deletes the task directory.
#
# Usage:
#   subagent-abandon.sh --task-id <id> --root <project-root>
#
# Exit codes:
#   0 — abandon complete
#   1 — error (task dir not found)

set -euo pipefail

err() { printf 'subagent-abandon: %s\n' "$*" >&2; exit 1; }

TASK_ID=""
ROOT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id) TASK_ID="$2"; shift 2 ;;
    --root)    ROOT="$2"; shift 2 ;;
    *)         err "unknown flag: $1" ;;
  esac
done

[ -n "$TASK_ID" ] || err "--task-id is required"
[ -n "$ROOT" ]    || err "--root is required"

case "$TASK_ID" in
  *[!A-Za-z0-9_.-]*|"") err "unsafe task-id: '$TASK_ID'" ;;
esac

ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || err "root does not exist: $ROOT"
TASK_DIR="$ROOT/.subagents/$TASK_ID"
[ -d "$TASK_DIR" ] || err "task dir does not exist: $TASK_DIR"

# Kill the subagent process if still alive
LOCK_FILE="$TASK_DIR/.lock"
if [ -f "$LOCK_FILE" ]; then
  read -r LOCK_LINE < "$LOCK_FILE" 2>/dev/null || true
  LOCK_PID="${LOCK_LINE#PID=}"
  LOCK_PID="${LOCK_PID%%[!0-9]*}"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    kill "$LOCK_PID" 2>/dev/null || true
    sleep 2
    if kill -0 "$LOCK_PID" 2>/dev/null; then
      kill -9 "$LOCK_PID" 2>/dev/null || true
      sleep 1
    fi
  fi
  rm -f "$LOCK_FILE"
fi

# Remove symlink in .worktrees/
[ -L "$ROOT/.worktrees/$TASK_ID" ] && rm -f "$ROOT/.worktrees/$TASK_ID"

# Force-remove git worktree and branch if present
WT_DIR="$TASK_DIR/worktree"
if [ -d "$WT_DIR" ]; then
  BRANCH=$(git -C "$WT_DIR" branch --show-current 2>/dev/null || echo "")
  git -C "$ROOT" worktree remove --force "$WT_DIR" 2>/dev/null || true
  if [ -n "$BRANCH" ]; then
    CURRENT_MAIN=$(git -C "$ROOT" branch --show-current 2>/dev/null || echo "")
    if [ "$BRANCH" != "$CURRENT_MAIN" ]; then
      git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null || true
    fi
  fi
fi

# Remove task directory
rm -rf "$TASK_DIR"

printf 'subagent-abandon: removed task=%s branch=%s\n' "$TASK_ID" "${BRANCH:-none}"