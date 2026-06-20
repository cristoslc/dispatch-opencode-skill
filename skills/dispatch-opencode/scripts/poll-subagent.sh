#!/usr/bin/env bash
# poll-subagent.sh — monitor a subagent task until completion, stuck, or timeout.
#
# Polls the lockfile and events.jsonl for a dispatched subagent task.
# Logs progress (events line count) each iteration. Exits when the
# lockfile disappears (completed), events stall past the stale threshold
# (stuck), or the maximum poll count is reached (timeout).
#
# Usage:
#   poll-subagent.sh --task-id <id> --root <project-root> \
#     [--interval <sec>] [--max-polls <n>] [--stale-threshold <sec>]
#
# Exit codes:
#   0 — task completed (lockfile gone, FINAL_OUTPUT.md present)
#   2 — task stuck (events.jsonl stale past threshold)
#   3 — timeout (max polls reached, lockfile still present)
#   1 — error (bad args, task dir not found)
#
# Output (stderr):
#   Progress lines: poll <i>/<max> task=<id> lines=<n> mtime=<epoch>
#   Status lines: COMPLETED / STUCK / TIMEOUT

set -euo pipefail

err() { printf 'poll-subagent: %s\n' "$*" >&2; exit 1; }

TASK_ID=""
ROOT=""
INTERVAL=30
MAX_POLLS=20
STALE_THRESHOLD=60

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id)          TASK_ID="$2"; shift 2 ;;
    --root)             ROOT="$2"; shift 2 ;;
    --interval)         INTERVAL="$2"; shift 2 ;;
    --max-polls)        MAX_POLLS="$2"; shift 2 ;;
    --stale-threshold)  STALE_THRESHOLD="$2"; shift 2 ;;
    *)                  err "unknown flag: $1" ;;
  esac
done

[ -n "$TASK_ID" ] || err "--task-id is required"
[ -n "$ROOT" ]    || err "--root is required"

case "$TASK_ID" in
  *[!A-Za-z0-9_.-]*|"") err "unsafe task-id: '$TASK_ID'" ;;
esac

ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || err "root does not exist: $ROOT"
TASK_DIR="$ROOT/.subagents/$TASK_ID"
LOCKFILE="$TASK_DIR/.lock"
EVENTS="$TASK_DIR/events.jsonl"

[ -d "$TASK_DIR" ] || err "task dir does not exist: $TASK_DIR"

# Poll loop
PREV_LINES=""
STALL_EPOCH=0

for i in $(seq 1 "$MAX_POLLS"); do
  # Check lockfile — gone means completed
  if [ ! -f "$LOCKFILE" ]; then
    printf 'poll %d/%d task=%s COMPLETED\n' "$i" "$MAX_POLLS" "$TASK_ID" >&2
    exit 0
  fi

  # Count events lines for progress signal
  LINES=0
  if [ -f "$EVENTS" ]; then
    LINES=$(wc -l < "$EVENTS" | tr -d ' ')
  fi

  # Get mtime of events.jsonl (epoch seconds)
  MTIME=0
  if [ -f "$EVENTS" ]; then
    MTIME=$(stat -f %m "$EVENTS" 2>/dev/null || stat -c %Y "$EVENTS" 2>/dev/null || echo 0)
  fi

  NOW=$(date +%s)
  printf 'poll %d/%d task=%s lines=%d mtime=%d\n' "$i" "$MAX_POLLS" "$TASK_ID" "$LINES" "$MTIME" >&2

  # Stuck detection: line count unchanged and stale mtime
  if [ "$LINES" = "$PREV_LINES" ] && [ "$PREV_LINES" != "" ]; then
    if [ "$STALL_EPOCH" -eq 0 ]; then
      STALL_EPOCH=$MTIME
    fi
    AGE=$(( NOW - STALL_EPOCH ))
    if [ "$AGE" -gt "$STALE_THRESHOLD" ]; then
      printf 'poll %d/%d task=%s STUCK: no progress for %ds\n' "$i" "$MAX_POLLS" "$TASK_ID" "$AGE" >&2
      exit 2
    fi
  else
    STALL_EPOCH=0
  fi

  PREV_LINES=$LINES

  sleep "$INTERVAL"
done

# Max polls reached — timeout
printf 'poll %d/%d task=%s TIMEOUT: lockfile still present after %ds\n' \
  "$MAX_POLLS" "$MAX_POLLS" "$TASK_ID" "$((MAX_POLLS * INTERVAL))" >&2
exit 3