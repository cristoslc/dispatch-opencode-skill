#!/usr/bin/env bash
# watcher-process.sh — process a single plan YAML for the watcher daemon.
#
# Called by watcher.sh for each new plan file found in the watch directory.
# Dispatches all tasks via run-plan.sh, polls each until completion, stuck,
# or TTL expiry, then moves the plan to completed/ or failed/.
#
# Usage:
#   watcher-process.sh --plan <plan-yaml> --root <project-root>
#
# Exit codes:
#   0 — all tasks completed successfully
#   1 — some or all tasks failed

set -euo pipefail

err() { printf 'watcher-process: %s\n' "$*" >&2; exit 1; }
log() { printf 'watcher-process: %s\n' "$*" >&2; }

PLAN_FILE=""
ROOT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) PLAN_FILE="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    *)      err "unknown flag: $1" ;;
  esac
done

[ -n "$PLAN_FILE" ] || err "--plan is required"
[ -n "$ROOT" ]      || err "--root is required"
[ -f "$PLAN_FILE" ] || err "plan file does not exist: $PLAN_FILE"

ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || err "root does not exist: $ROOT"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_PLAN="$SCRIPT_DIR/run-plan.sh"
CLEANUP="$SCRIPT_DIR/subagent-cleanup.sh"
ABANDON="$SCRIPT_DIR/subagent-abandon.sh"

PLAN_DIR="$(dirname "$PLAN_FILE")"
WATCH_DIR="$(cd "$PLAN_DIR/.." && pwd)"
PLAN_BASENAME="$(basename "$PLAN_FILE")"

# Parse plan YAML for per-task ttl_sec
TASK_TTLS=$(python3 -c "
import yaml, sys, json
with open('$PLAN_FILE') as f:
    plan = yaml.safe_load(f)
tasks = plan.get('tasks', [])
result = {}
for t in tasks:
    tid = t.get('id', '')
    mode = t.get('mode', 'foreground')
    ttl = t.get('ttl_sec', 1800)
    result[tid] = {'ttl': ttl, 'mode': mode}
print(json.dumps(result))
" 2>/dev/null) || err "failed to parse plan YAML for ttl_sec"

# Step 1: Move plan to processing/ subdirectory
PROCESSING_DIR="$WATCH_DIR/processing"
COMPLETED_DIR="$WATCH_DIR/completed"
FAILED_DIR="$WATCH_DIR/failed"
RESULTS_DIR="$WATCH_DIR/results"

PROCESSED_PLAN="$PROCESSING_DIR/$PLAN_BASENAME"
mv "$PLAN_FILE" "$PROCESSED_PLAN"
log "moved plan to processing: $PROCESSED_PLAN"

# Step 2: Call run-plan.sh to dispatch
log "dispatching plan: $PROCESSED_PLAN"
RUN_OUTPUT=$(bash "$RUN_PLAN" --plan "$PROCESSED_PLAN" --root "$ROOT" 2>&1) || {
  log "run-plan.sh failed for $PLAN_BASENAME"
  mv "$PROCESSED_PLAN" "$FAILED_DIR/$PLAN_BASENAME"
  exit 1
}

# Step 3: Parse JSON output to get task metadata
# The JSON is the last line of output (all other output is stderr)
PLAN_JSON=$(echo "$RUN_OUTPUT" | grep '^{' | tail -1 || echo "")
if [ -z "$PLAN_JSON" ]; then
  log "no JSON output from run-plan.sh"
  mv "$PROCESSED_PLAN" "$FAILED_DIR/$PLAN_BASENAME"
  exit 1
fi

log "plan JSON: $PLAN_JSON"

# Extract task list as JSON array
TASKS_JSON=$(echo "$PLAN_JSON" | python3 -c "
import json, sys
plan = json.load(sys.stdin)
tasks = plan.get('tasks', [])
for t in tasks:
    print(json.dumps(t))
" 2>/dev/null || echo "")

if [ -z "$TASKS_JSON" ]; then
  log "no tasks in plan output"
  mv "$PROCESSED_PLAN" "$FAILED_DIR/$PLAN_BASENAME"
  exit 1
fi

# Step 4: Poll each task
POLL_INTERVAL=15
MAX_POLLS=120
STALE_THRESHOLD=60
ALL_OK=1

while IFS= read -r TASK_JSON; do
  [ -n "$TASK_JSON" ] || continue

  TASK_ID=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  TASK_STATUS=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

  [ -n "$TASK_ID" ] || continue

  # Skip tasks that were not dispatched
  if [ "$TASK_STATUS" = "skipped" ]; then
    REASON=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason','unknown'))" 2>/dev/null || echo "unknown")
    log "task=$TASK_ID skipped: $REASON"
    # Write failure summary
    cat > "$RESULTS_DIR/$TASK_ID.md" <<OUT
# watcher-process result

task_id: $TASK_ID
status: skipped
reason: $REASON
OUT
    ALL_OK=0
    continue
  fi

  TASK_DIR="$ROOT/.subagents/$TASK_ID"
  LOCKFILE="$TASK_DIR/.lock"
  EVENTS="$TASK_DIR/events.jsonl"
  TASK_MODE=$(echo "$TASK_TTLS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$TASK_ID', {}).get('mode', 'foreground'))" 2>/dev/null || echo "foreground")
  TTL=$(echo "$TASK_TTLS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$TASK_ID', {}).get('ttl', 1800))" 2>/dev/null || echo "1800")

  # Skip foreground tasks — they are handled by run-plan.sh directly
  if [ "$TASK_MODE" = "foreground" ]; then
    log "task=$TASK_ID mode=foreground — skipping (handled by run-plan.sh directly)"
    continue
  fi

  log "polling task=$TASK_ID ttl=${TTL}s interval=${POLL_INTERVAL}s max-polls=$MAX_POLLS"

  # Get dispatch time from lockfile mtime
  DISPATCH_TIME=0
  if [ -f "$LOCKFILE" ]; then
    DISPATCH_TIME=$(stat -f %m "$LOCKFILE" 2>/dev/null || stat -c %Y "$LOCKFILE" 2>/dev/null || echo "0")
  fi

  # Poll loop
  PREV_LINES=""
  STALL_EPOCH=0
  TASK_RESULT=""
  TASK_EXIT_CODE=0

  for i in $(seq 1 "$MAX_POLLS"); do
    NOW=$(date +%s)

    # Check TTL
    if [ "$DISPATCH_TIME" -gt 0 ] && [ "$TTL" -gt 0 ]; then
      AGE=$((NOW - DISPATCH_TIME))
      if [ "$AGE" -gt "$TTL" ]; then
        log "task=$TASK_ID TTL exceeded: ${AGE}s > ${TTL}s — abandoning"
        TASK_RESULT="ttl"
        TASK_EXIT_CODE=3
        break
      fi
    fi

    # Check lockfile — gone means completed
    if [ ! -f "$LOCKFILE" ]; then
      log "task=$TASK_ID completed (lockfile gone)"
      TASK_RESULT="completed"
      TASK_EXIT_CODE=0
      break
    fi

    # Count events lines for progress signal
    LINES=0
    if [ -f "$EVENTS" ]; then
      LINES=$(wc -l < "$EVENTS" | tr -d ' ')
    fi

    # Get mtime of events.jsonl
    MTIME=0
    if [ -f "$EVENTS" ]; then
      MTIME=$(stat -f %m "$EVENTS" 2>/dev/null || stat -c %Y "$EVENTS" 2>/dev/null || echo 0)
    fi

    # Stuck detection: line count unchanged and stale mtime
    if [ "$LINES" = "$PREV_LINES" ] && [ "$PREV_LINES" != "" ]; then
      if [ "$STALL_EPOCH" -eq 0 ]; then
        STALL_EPOCH=$MTIME
      fi
      STALL_AGE=$((NOW - STALL_EPOCH))
      if [ "$STALL_AGE" -gt "$STALE_THRESHOLD" ]; then
        log "task=$TASK_ID STUCK: no progress for ${STALL_AGE}s — abandoning"
        TASK_RESULT="stuck"
        TASK_EXIT_CODE=2
        break
      fi
    else
      STALL_EPOCH=0
    fi

    PREV_LINES=$LINES

    sleep "$POLL_INTERVAL"
  done

  # If loop exhausted without break — timeout
  if [ -z "$TASK_RESULT" ]; then
    log "task=$TASK_ID TIMEOUT: lockfile still present after $((MAX_POLLS * POLL_INTERVAL))s"
    TASK_RESULT="timeout"
    TASK_EXIT_CODE=3
  fi

  # Step 5/6: Write result and call cleanup or abandon
  case "$TASK_RESULT" in
    completed)
      # Read FINAL_OUTPUT.md for summary
      FINAL_OUTPUT="$TASK_DIR/FINAL_OUTPUT.md"
      if [ -f "$FINAL_OUTPUT" ]; then
        cp "$FINAL_OUTPUT" "$RESULTS_DIR/$TASK_ID.md"
      else
        cat > "$RESULTS_DIR/$TASK_ID.md" <<OUT
# watcher-process result

task_id: $TASK_ID
status: completed
OUT
      fi
      log "task=$TASK_ID result=completed"
      if [ -x "$CLEANUP" ]; then
        bash "$CLEANUP" --task-id "$TASK_ID" --root "$ROOT" 2>&1 | log || true
      fi
      ;;
    stuck|ttl|timeout)
      cat > "$RESULTS_DIR/$TASK_ID.md" <<OUT
# watcher-process result

task_id: $TASK_ID
status: $TASK_RESULT
OUT
      log "task=$TASK_ID result=$TASK_RESULT"
      if [ -x "$ABANDON" ]; then
        bash "$ABANDON" --task-id "$TASK_ID" --root "$ROOT" 2>&1 | log || true
      fi
      ALL_OK=0
      ;;
  esac

done < <(echo "$TASKS_JSON")

# Step 7: Move processed plan to completed/ or failed/
if [ "$ALL_OK" -eq 1 ]; then
  mv "$PROCESSED_PLAN" "$COMPLETED_DIR/$PLAN_BASENAME"
  log "plan moved to completed: $COMPLETED_DIR/$PLAN_BASENAME"
else
  mv "$PROCESSED_PLAN" "$FAILED_DIR/$PLAN_BASENAME"
  log "plan moved to failed: $FAILED_DIR/$PLAN_BASENAME"
fi

exit $((1 - ALL_OK))
