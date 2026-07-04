#!/usr/bin/env bash
# run-plan.sh — agent entry point: validate plan, prepare worktrees, dispatch
# tasks, return lockfile list.
#
# Reads a plan YAML, validates it, dispatches each task via dispatch.sh,
# and returns structured JSON on stdout. Exits immediately — does NOT
# poll or wait for tasks to complete.
#
# The agent parses the JSON output, extracts lockfile paths and PIDs,
# and monitors them on its own interval.
#
# Usage:
#   run-plan.sh --plan <plan.yaml> [--root <project-root>]
#
# --root is optional. When provided, it sets the project root for dispatch
# and .subagents/ tracking. When omitted, the plan file's directory is used.
#
# Exit codes:
#   0 — plan processed (some tasks may have been skipped)
#   1 — error (bad plan, no valid tasks)

set -euo pipefail

err() { printf 'run-plan: %s\n' "$*" >&2; exit 1; }
log() { printf 'run-plan: %s\n' "$*" >&2; }

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
[ -f "$PLAN_FILE" ] || err "plan file does not exist: $PLAN_FILE"

PLAN_DIR="$(cd "$(dirname "$PLAN_FILE")" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"

[ -x "$DISPATCH" ] || err "dispatch.sh not found or not executable: $DISPATCH"

# Resolve root: use --root if provided, otherwise plan dir
if [ -n "$ROOT" ]; then
  ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || err "root does not exist: $ROOT"
else
  ROOT="$PLAN_DIR"
fi

# Parse and validate plan YAML, produce TSV for dispatch loop
TASKS_TSV=$(python3 -c "
import yaml, sys, os

with open('$PLAN_FILE') as f:
    plan = yaml.safe_load(f)

tasks = plan.get('tasks', [])
if not tasks:
    print('ERROR: plan has no tasks', file=sys.stderr)
    sys.exit(1)

dangerously_write_trunk = plan.get('dangerously_write_trunk', False)

for t in tasks:
    tid    = t.get('id', '')
    kind   = t.get('kind', '')
    model  = t.get('model', '')
    agent  = t.get('agent', '')
    prompt = t.get('prompt', '')
    target = t.get('target', '')
    worktree = t.get('worktree', '')
    pr_title = t.get('pr_title', '')
    mode   = t.get('mode', 'foreground')
    ttl_sec = t.get('ttl_sec', 1800)

    if not tid:
        print('task missing id', file=sys.stderr)
        sys.exit(1)
    if not kind:
        print(f'task {tid} missing kind', file=sys.stderr)
        sys.exit(1)
    if not model:
        print(f'task {tid} missing model', file=sys.stderr)
        sys.exit(1)
    if not prompt:
        print(f'task {tid} missing prompt', file=sys.stderr)
        sys.exit(1)

    # Resolve prompt path relative to plan dir
    if not os.path.isabs(prompt):
        prompt = os.path.join('$PLAN_DIR', prompt)

    agent = agent if agent else '-'
    target = target if target else '-'
    worktree = worktree if worktree else '-'
    pr_title = pr_title if pr_title else '-'
    dwf = '1' if dangerously_write_trunk else '0'
    print(f'{tid}\t{kind}\t{model}\t{agent}\t{prompt}\t{target}\t{worktree}\t{pr_title}\t{dwf}')
" 2>/dev/null) || err "plan parsing failed — check YAML syntax and required fields (id, kind, model, prompt)"

# Allocate plan directory for tracking
PLAN_TS=$(date -u +%Y%m%dT%H%M%SZ)
PLAN_ID="plan-${PLAN_TS}"
PLAN_DIR_OUT="$ROOT/.subagents/$PLAN_ID"
mkdir -p "$PLAN_DIR_OUT"

TASK_COUNT=$(echo "$TASKS_TSV" | wc -l | tr -d ' ')
log "plan_id=$PLAN_ID tasks=$TASK_COUNT"

# Dispatch each task, collect results
RESULTS_JSON="["
FIRST=1
DISPATCHED=0
SKIPPED=0

while IFS=$'\t' read -r TID TKIND TMODEL TAGENT TPROMPT TTARGET TWORKTREE TPR_TITLE TDWF; do

  # Build dispatch args
  DISPATCH_ARGS=(
    --root "$ROOT"
    --cwd "$ROOT"
    --kind "$TKIND"
    --model "$TMODEL"
    --agent "$TAGENT"
    --prompt-file "$TPROMPT"
    --target "$TTARGET"
    --task-id "$TID"
  )
  [ -n "$TWORKTREE" ] && [ "$TWORKTREE" != "-" ] && DISPATCH_ARGS+=(--worktree "$TWORKTREE")
  [ -n "$TPR_TITLE" ] && [ "$TPR_TITLE" != "-" ] && log "ignoring pr_title for task=$TID (pr-work kind removed)"
  [ "$TDWF" = "1" ] && DISPATCH_ARGS+=(--dangerously-write-trunk)

  # Call dispatch.sh — captures JSON output on stdout
  DISPATCH_OUT=$("$DISPATCH" "${DISPATCH_ARGS[@]}" 2>"$PLAN_DIR_OUT/$TID-dispatch-stderr.log") || {
    # Dispatch failed — record as skipped
    ERRMSG=$(cat "$PLAN_DIR_OUT/$TID-dispatch-stderr.log" 2>/dev/null | tail -1 | sed 's/.*: //' || echo "dispatch failed")
    [ "$FIRST" -eq 1 ] && FIRST=0 || RESULTS_JSON+=","
    RESULTS_JSON+="{\"id\":\"$TID\",\"status\":\"skipped\",\"reason\":\"$ERRMSG\"}"
    SKIPPED=$((SKIPPED + 1))
    log "skipped task=$TID: $ERRMSG"
    continue
  }

  # Append dispatch result
  [ "$FIRST" -eq 1 ] && FIRST=0 || RESULTS_JSON+=","
  RESULTS_JSON+="$DISPATCH_OUT"
  DISPATCHED=$((DISPATCHED + 1))
  log "dispatched task=$TID"

done < <(echo "$TASKS_TSV")

RESULTS_JSON+="]"

# Write plan output
printf '{"plan_id":"%s","tasks":%s}\n' "$PLAN_ID" "$RESULTS_JSON"

log "done — dispatched=$DISPATCHED skipped=$SKIPPED"

[ "$DISPATCHED" -gt 0 ] || err "no tasks were successfully dispatched"