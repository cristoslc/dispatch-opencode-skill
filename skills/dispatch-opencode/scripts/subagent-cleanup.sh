#!/usr/bin/env bash
# subagent-cleanup.sh — remove a completed task's artifacts and worktree.
#
# Called after the agent reads FINAL_OUTPUT.md and merges the work.
# Removes .lock, worktree symlink, git worktree, and task directory.
# Does NOT force-remove — the worktree should be clean after merge.
#
# Usage:
#   subagent-cleanup.sh --task-id <id> --root <project-root>
#
# Exit codes:
#   0 — cleanup complete
#   1 — error

set -euo pipefail

err() { printf 'subagent-cleanup: %s\n' "$*" >&2; exit 1; }

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

# Remove .lock if still present
rm -f "$TASK_DIR/.lock"

# Remove symlink in .worktrees/
[ -L "$ROOT/.worktrees/$TASK_ID" ] && rm -f "$ROOT/.worktrees/$TASK_ID"

# Remove git worktree if present
WT_DIR="$TASK_DIR/worktree"
if [ -d "$WT_DIR" ]; then
  git -C "$ROOT" worktree remove "$WT_DIR" 2>/dev/null \
    || err "git worktree remove failed (may have uncommitted changes — use subagent-abandon.sh)"
fi

# Remove task directory
rm -rf "$TASK_DIR"

printf 'subagent-cleanup: removed task=%s\n' "$TASK_ID"