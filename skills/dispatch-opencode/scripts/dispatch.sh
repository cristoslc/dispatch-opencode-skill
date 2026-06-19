#!/usr/bin/env bash
# dispatch.sh — internal engine: prepare and spawn a single subagent task.
#
# Called by run-plan.sh. NOT agent-facing.
#
# Creates .subagents/<task-id>/, writes prompt + start-subagent.sh, spawns
# it in the background, confirms .lock appeared, returns task metadata
# as JSON on stdout.
#
# Usage:
#   dispatch.sh --root <project-root> --cwd <worktree-or-project-dir> \
#     --kind <kind> --model <model> --agent <agent> \
#     --prompt-file <path> [--target <path>] --task-id <id> \
#     [--worktree <branch>] [--pr-title <title>]
#
# Note: --target is required for single-file-fix and headless-spike.
#
# Exit codes:
#   0 — task dispatched, .lock confirmed
#   1 — error (bad args, spawn failure)
#
# Environment:
#   OPENCODE_SERVER_URL      — if set, start-subagent.sh uses --attach mode
#   OPENCODE_SERVER_PASSWORD  — required when OPENCODE_SERVER_URL is set

set -euo pipefail

err() { printf 'dispatch: %s\n' "$*" >&2; exit 1; }

ROOT=""
CWD=""
KIND=""
MODEL=""
AGENT=""
PROMPT_FILE=""
TARGET=""
TASK_ID=""
WORKTREE_BRANCH=""
PR_TITLE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)        ROOT="$2"; shift 2 ;;
    --cwd)         CWD="$2"; shift 2 ;;
    --kind)        KIND="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --agent)       AGENT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --target)      TARGET="$2"; shift 2 ;;
    --task-id)     TASK_ID="$2"; shift 2 ;;
    --worktree)    WORKTREE_BRANCH="$2"; shift 2 ;;
    *)             err "unknown flag: $1" ;;
  esac
done

[ -n "$ROOT" ]        || err "--root is required"
[ -n "$CWD" ]         || err "--cwd is required"
[ -n "$KIND" ]        || err "--kind is required"
[ -n "$MODEL" ]       || err "--model is required"
: "${AGENT:=default}"
[ "$AGENT" != "-" ]  || AGENT="default"
[ -n "$PROMPT_FILE" ] || err "--prompt-file is required"

if [ "$KIND" != "multi-file-fix" ]; then
  [ -n "$TARGET" ] || err "--target is required"
fi

# Validate worktree branch if provided
if [ -n "$WORKTREE_BRANCH" ]; then
  case "$WORKTREE_BRANCH" in
    *[!A-Za-z0-9_./-]*|"") err "unsafe worktree branch: '$WORKTREE_BRANCH'" ;;
  esac
fi
[ -n "$TASK_ID" ]     || err "--task-id is required"

[ -d "$ROOT" ]        || err "root does not exist: $ROOT"
[ -d "$CWD" ]         || err "cwd does not exist: $CWD"
[ -f "$PROMPT_FILE" ] || err "prompt-file does not exist: $PROMPT_FILE"

case "$TASK_ID" in
  *[!A-Za-z0-9_.-]*|"") err "unsafe task-id: '$TASK_ID'" ;;
esac

ROOT="$(cd "$ROOT" && pwd)"
CWD="$(cd "$CWD" && pwd)"

# Verify CWD
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
bash "$SKILL_DIR/scripts/verify-cwd.sh" "$CWD" >/dev/null || err "cwd verification failed"

# Allocate task directory
SUBAGENTS_DIR="$ROOT/.subagents"
TASK_DIR="$SUBAGENTS_DIR/$TASK_ID"
mkdir -p "$TASK_DIR"

# Copy prompt (guard against source == destination)
if [ "$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")" = "$TASK_DIR/prompt.md" ]; then
  err "prompt file $PROMPT_FILE resolves to the same path as $TASK_DIR/prompt.md — place prompts outside .subagents/"
fi
cp "$PROMPT_FILE" "$TASK_DIR/prompt.md"

# Prepare worktree if declared
WORKTREE_DIR=""
if [ -n "$WORKTREE_BRANCH" ]; then
  WORKTREE_DIR="$TASK_DIR/worktree"
  # Check for an existing worktree on this branch first
  EXISTING_WT=$(git worktree list 2>/dev/null | awk -v b="$WORKTREE_BRANCH" '{ gsub(/[\[\]]/, "", $3); if ($3 == b || $3 == "refs/heads/"b) { print $1; exit } }' || true)
  if [ -n "$EXISTING_WT" ] && [ -d "$EXISTING_WT" ]; then
    # Use existing worktree — don't create a new one
    WORKTREE_DIR="$EXISTING_WT"
  else
    # Check for existing worktree symlink to prevent duplicate dispatch
    [ -L "$ROOT/.worktrees/$TASK_ID" ] && err "worktree already exists for task=$TASK_ID"
    git worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_DIR" HEAD >/dev/null 2>&1 \
      || err "worktree creation failed for task=$TASK_ID branch=$WORKTREE_BRANCH"
    mkdir -p "$ROOT/.worktrees"
    ln -sf "$WORKTREE_DIR" "$ROOT/.worktrees/$TASK_ID"
  fi
  # CWD becomes the worktree
  CWD="$WORKTREE_DIR"
fi

# Determine template and render
TEMPLATES_DIR="$SKILL_DIR/templates/cli"
TS=$(date -u +%Y%m%dT%H%M%SZ)

case "$KIND" in
  single-file-fix)
    TPL="$TEMPLATES_DIR/single-file-fix.sh.j2"
    [ -f "$TPL" ] || err "no template for kind=$KIND: $TPL"
    export TPL TASK_ID TS CWD TASK_DIR MODEL AGENT TARGET
    python3 << 'PYEOF' 2>"$TASK_DIR/template-render-errors.log" || err "template rendering failed (see template-render-errors.log)"
import os, shlex, sys
tpl_path = os.environ['TPL']
task_id = os.environ['TASK_ID']
ts = os.environ['TS']
cwd = os.environ['CWD']
task_dir = os.environ['TASK_DIR']
model = os.environ['MODEL']
agent = os.environ['AGENT']
target = os.environ['TARGET']
with open(tpl_path) as f:
    tpl = f.read()
vars = {
    'task_id':       shlex.quote(task_id),
    'generated_at':  ts,
    'cwd':           shlex.quote(cwd),
    'task_dir':      shlex.quote(task_dir),
    'model':         shlex.quote(model),
    'agent':         shlex.quote(agent),
    'target_file':   shlex.quote(target),
}
for k, v in vars.items():
    tpl = tpl.replace('{{ ' + k + ' | shellquote }}', v)
    tpl = tpl.replace('{{ ' + k + ' }}', v)
with open(os.path.join(task_dir, 'start-subagent.sh'), 'w') as f:
    f.write(tpl)
PYEOF
    ;;
  headless-spike)
    TPL="$TEMPLATES_DIR/headless-spike.sh.j2"
    [ -f "$TPL" ] || err "no template for kind=$KIND: $TPL"
    export TPL TASK_ID TS CWD TASK_DIR MODEL AGENT TARGET
    python3 << 'PYEOF' 2>"$TASK_DIR/template-render-errors.log" || err "template rendering failed (see template-render-errors.log)"
import os, shlex, sys
tpl_path = os.environ['TPL']
task_id = os.environ['TASK_ID']
ts = os.environ['TS']
cwd = os.environ['CWD']
task_dir = os.environ['TASK_DIR']
model = os.environ['MODEL']
agent = os.environ['AGENT']
target = os.environ['TARGET']
with open(tpl_path) as f:
    tpl = f.read()
vars = {
    'task_id':       shlex.quote(task_id),
    'generated_at':  ts,
    'cwd':           shlex.quote(cwd),
    'task_dir':      shlex.quote(task_dir),
    'model':         shlex.quote(model),
    'agent':         shlex.quote(agent),
    'report_path':   shlex.quote(target),
}
for k, v in vars.items():
    tpl = tpl.replace('{{ ' + k + ' | shellquote }}', v)
    tpl = tpl.replace('{{ ' + k + ' }}', v)
with open(os.path.join(task_dir, 'start-subagent.sh'), 'w') as f:
    f.write(tpl)
PYEOF
    ;;
  multi-file-fix)
    TPL="$TEMPLATES_DIR/multi-file-fix.sh.j2"
    [ -f "$TPL" ] || err "no template for kind=$KIND: $TPL"
    export TPL TASK_ID TS CWD TASK_DIR MODEL AGENT
    python3 << 'PYEOF' 2>"$TASK_DIR/template-render-errors.log" || err "template rendering failed (see template-render-errors.log)"
import os, shlex, sys
tpl_path = os.environ['TPL']
task_id = os.environ['TASK_ID']
ts = os.environ['TS']
cwd = os.environ['CWD']
task_dir = os.environ['TASK_DIR']
model = os.environ['MODEL']
agent = os.environ['AGENT']
with open(tpl_path) as f:
    tpl = f.read()
vars = {
    'task_id':       shlex.quote(task_id),
    'generated_at':  ts,
    'cwd':           shlex.quote(cwd),
    'task_dir':      shlex.quote(task_dir),
    'model':         shlex.quote(model),
    'agent':         shlex.quote(agent),
}
for k, v in vars.items():
    tpl = tpl.replace('{{ ' + k + ' | shellquote }}', v)
    tpl = tpl.replace('{{ ' + k + ' }}', v)
with open(os.path.join(task_dir, 'start-subagent.sh'), 'w') as f:
    f.write(tpl)
PYEOF
    ;;
  *) err "unknown kind: $KIND (single-file-fix | multi-file-fix | headless-spike)" ;;
esac

chmod +x "$TASK_DIR/start-subagent.sh"

# Spawn — redirect all subagent output to log files, not parent stdout
bash "$TASK_DIR/start-subagent.sh" >"$TASK_DIR/dispatch-stdout.log" 2>"$TASK_DIR/dispatch-stderr.log" &
PID=$!

# Wait for .lock to appear (spawn confirmation)
for i in $(seq 1 15); do
  [ -f "$TASK_DIR/.lock" ] && break
  sleep 0.5
done

if [ ! -f "$TASK_DIR/.lock" ]; then
  # Spawn failed — clean up
  kill "$PID" 2>/dev/null || true
  err "subagent failed to write .lock within 7.5s — check stderr.log"
fi

# Return task metadata as JSON
LOCKFILE="$TASK_DIR/.lock"
WT_JSON="null"
if [ -n "$WORKTREE_BRANCH" ] && [ -L "$ROOT/.worktrees/$TASK_ID" ]; then
  WT_JSON="\"$ROOT/.worktrees/$TASK_ID\""
fi

printf '{"id":"%s","lockfile":"%s","task_dir":"%s","pid":%d,"worktree":%s,"status":"dispatched"}\n' \
  "$TASK_ID" "$LOCKFILE" "$TASK_DIR" "$PID" "$WT_JSON"