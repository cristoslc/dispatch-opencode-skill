#!/usr/bin/env bash
# dispatch.sh — orchestrate an async subagent via .subagents/ lock-watch protocol.
#
# Creates .subagents/<task-id>/, writes prompt + start-subagent.sh, spawns it
# in the background, polls .lock, reads FINAL_OUTPUT.md on completion.
#
# Usage:
#   dispatch.sh <kind> <cwd> <model> <agent> <prompt-file> <target-or-report> [--timeout <sec>]
#
# Kinds:
#   single-file-fix  requires <target-or-report> = target file path
#   headless-spike   requires <target-or-report> = report path
#
# Exit codes:
#   0   — subagent completed successfully (FINAL_OUTPUT.md written)
#   124 — timeout / stall detected
#   1   — other error
#
# Environment:
#   OPENCODE_SERVER_URL      — if set, start-subagent.sh uses --attach mode
#   OPENCODE_SERVER_PASSWORD  — required when OPENCODE_SERVER_URL is set

set -euo pipefail

err()  { printf 'dispatch: %s\n' "$*" >&2; exit 1; }
log()  { printf 'dispatch: %s\n' "$*"; }

KIND="${1:-}"; shift || err "usage: dispatch.sh <kind> <cwd> <model> <agent> <prompt-file> <target-or-report> [--timeout <sec>]"
CWD="${1:-}"; shift || err "missing cwd"
MODEL="${1:-}"; shift || err "missing model"
AGENT="${1:-}"; shift || err "missing agent"
PROMPT_FILE="${1:-}"; shift || err "missing prompt-file"
TARGET="${1:-}"; shift || err "missing target-or-report"

TIMEOUT=600
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) err "unknown flag: $1" ;;
  esac
done

[ -d "$CWD" ] || err "cwd does not exist: $CWD"
[ -f "$PROMPT_FILE" ] || err "prompt-file does not exist: $PROMPT_FILE"

# Verify CWD
bash "$(cd "$(dirname "$0")/.." && pwd)/scripts/verify-cwd.sh" "$CWD" || err "cwd verification failed"

# Allocate task ID and directory
TS=$(date -u +%Y%m%dT%H%M%SZ)
DIGEST=$(shasum -a 256 "$PROMPT_FILE" | cut -c1-8)
TASK_ID="${TS}-${DIGEST}"
SUBAGENTS_DIR="$CWD/.subagents"
TASK_DIR="$SUBAGENTS_DIR/$TASK_ID"
mkdir -p "$TASK_DIR"

log "task_id=$TASK_ID dir=$TASK_DIR"

# Copy prompt
cp "$PROMPT_FILE" "$TASK_DIR/prompt.md"

# Determine template and render
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$SKILL_DIR/templates/cli"

case "$KIND" in
  single-file-fix)
    TPL="$TEMPLATES_DIR/single-file-fix.sh.j2"
    [ -f "$TPL" ] || err "no template for kind=$KIND: $TPL"
    # Simple shell substitution for the template variables
    python3 -c "
import shlex, sys
with open('$TPL') as f:
    tpl = f.read()
vars = {
    'task_id':    shlex.quote('$TASK_ID'),
    'generated_at':  '$TS',
    'cwd':        shlex.quote('$CWD'),
    'model':      shlex.quote('$MODEL'),
    'agent':      shlex.quote('$AGENT'),
    'timeout_sec':   shlex.quote('$TIMEOUT'),
    'target_file':   shlex.quote('$TARGET'),
}
for k, v in vars.items():
    tpl = tpl.replace('{{ ' + k + ' | shellquote }}', v)
    tpl = tpl.replace('{{ ' + k + ' }}', v)
with open('$TASK_DIR/start-subagent.sh', 'w') as f:
    f.write(tpl)
" 2>/dev/null || err "template rendering failed"
    ;;
  headless-spike)
    TPL="$TEMPLATES_DIR/headless-spike.sh.j2"
    [ -f "$TPL" ] || err "no template for kind=$KIND: $TPL"
    python3 -c "
import shlex, sys
with open('$TPL') as f:
    tpl = f.read()
vars = {
    'task_id':    shlex.quote('$TASK_ID'),
    'generated_at':  '$TS',
    'cwd':        shlex.quote('$CWD'),
    'model':      shlex.quote('$MODEL'),
    'agent':      shlex.quote('$AGENT'),
    'timeout_sec':   shlex.quote('$TIMEOUT'),
    'report_path':   shlex.quote('$TARGET'),
}
for k, v in vars.items():
    tpl = tpl.replace('{{ ' + k + ' | shellquote }}', v)
    tpl = tpl.replace('{{ ' + k + ' }}', v)
with open('$TASK_DIR/start-subagent.sh', 'w') as f:
    f.write(tpl)
" 2>/dev/null || err "template rendering failed"
    ;;
  *) err "unknown kind: $KIND (single-file-fix | headless-spike)" ;;
esac

chmod +x "$TASK_DIR/start-subagent.sh"

# Spawn
bash "$TASK_DIR/start-subagent.sh" &
PID=$!
log "spawned pid=$PID wait_timeout=${TIMEOUT}s"

# Wait for .lock to appear (subagent writes it on start)
for i in $(seq 1 15); do
  if [ -f "$TASK_DIR/.lock" ]; then
    break
  fi
  sleep 0.5
done

if [ ! -f "$TASK_DIR/.lock" ]; then
  log "subagent failed to write .lock within 7.5s — check stderr.log"
  cat "$TASK_DIR/stderr.log" 2>/dev/null
  exit 1
fi

# Poll loop
START_TS=$(date +%s)
while [ -f "$TASK_DIR/.lock" ]; do
  AGE=$(( $(date +%s) - START_TS ))
  if [ "$AGE" -gt "$TIMEOUT" ]; then
    log "stall detected after ${AGE}s — killing pid=$PID"
    kill "$PID" 2>/dev/null || true
    sleep 1
    kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
    rm -f "$TASK_DIR/.lock"
    echo "exit_code: 124" >> "$TASK_DIR/FINAL_OUTPUT.md" 2>/dev/null || true
    exit 124
  fi
  sleep 2
done

# Check result
log "lock cleared — reading FINAL_OUTPUT.md"
if [ -f "$TASK_DIR/FINAL_OUTPUT.md" ]; then
  head -10 "$TASK_DIR/FINAL_OUTPUT.md"
  EXIT_CODE=$(grep -E '^exit_code: ' "$TASK_DIR/FINAL_OUTPUT.md" | cut -d' ' -f2 || echo "0")
  exit "$EXIT_CODE"
else
  log "FINAL_OUTPUT.md not found — subagent did not complete"
  exit 1
fi
