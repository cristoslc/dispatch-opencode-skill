#!/usr/bin/env bash
# test_dispatch_refactor.sh — test the refactored dispatch.sh + lifecycle scripts.
#
# Tests:
#   1. dispatch.sh creates task dir, spawns, confirms .lock, returns JSON
#   2. subagent-cleanup.sh removes task artifacts
#   3. subagent-abandon.sh kills process and force-removes
#   4. run-plan.sh validates and dispatches from a plan YAML
#
# Usage: bash tests/test_dispatch_refactor.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-dispatch-test.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "dispatch@test"
git config user.name "Dispatch Test"

mkdir -p src
printf 'def add(a, b):\n    return a - b\n' > src/foo.py
printf 'fix the bug\n' > prompt.md
git add -A && git commit -q -m fixture

ROOT="$WORK"

# --- Test 1: dispatch.sh creates task dir and returns JSON ---

echo "test: dispatch.sh with --root/--task-id flags..."
OUT=$("$DISPATCH" \
  --root "$ROOT" \
  --cwd "$ROOT" \
  --kind single-file-fix \
  --model ollama-cloud/deepseek-v4-flash:cloud \
  --agent build \
  --prompt-file "$ROOT/prompt.md" \
  --target src/foo.py \
  --task-id test-dispatch-1 \
  --dangerously-write-trunk \
  2>/dev/null) || err "dispatch.sh failed"

# Parse JSON output
echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['id']=='test-dispatch-1'; assert d['status']=='dispatched'; assert 'lockfile' in d; assert 'pid' in d" 2>/dev/null \
  || err "dispatch.sh JSON output invalid: $OUT"
ok "dispatch.sh returned valid JSON"

TASK_DIR="$ROOT/.subagents/test-dispatch-1"
[ -d "$TASK_DIR" ] || err "task dir not created: $TASK_DIR"
ok "task dir exists"

[ -f "$TASK_DIR/.lock" ] || err ".lock not created"
ok ".lock exists"

[ -f "$TASK_DIR/prompt.md" ] || err "prompt.md not copied"
ok "prompt.md copied"

# Wait for subagent to finish (or timeout)
echo "test: waiting for subagent to complete..."
for i in $(seq 1 60); do
  [ ! -f "$TASK_DIR/.lock" ] && break
  sleep 2
done

if [ -f "$TASK_DIR/.lock" ]; then
  # Subagent still running — abandon it
  "$ABANDON" --task-id test-dispatch-1 --root "$ROOT" 2>/dev/null
  echo "test: NOTE subagent did not complete within 120s (model variability)"
else
  ok "subagent completed (.lock removed)"

  [ -f "$TASK_DIR/FINAL_OUTPUT.md" ] || err "FINAL_OUTPUT.md not written"
  ok "FINAL_OUTPUT.md written"

  # Cleanup
  "$CLEANUP" --task-id test-dispatch-1 --root "$ROOT" 2>/dev/null \
    || err "subagent-cleanup.sh failed"
  ok "subagent-cleanup.sh succeeded"

  [ ! -d "$TASK_DIR" ] || err "task dir still exists after cleanup"
  ok "task dir removed after cleanup"
fi

# --- Test 2: dispatch.sh with worktree ---

echo "test: dispatch.sh with --worktree flag..."
OUT2=$("$DISPATCH" \
  --root "$ROOT" \
  --cwd "$ROOT" \
  --kind single-file-fix \
  --model ollama-cloud/deepseek-v4-flash:cloud \
  --agent build \
  --prompt-file "$ROOT/prompt.md" \
  --target src/foo.py \
  --task-id test-wt-1 \
  --worktree test-wt-1-branch \
  2>/dev/null) || err "dispatch.sh with worktree failed"

echo "$OUT2" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['worktree'] is not None, 'worktree should be set'" 2>/dev/null \
  || err "dispatch.sh worktree JSON invalid: $OUT2"
ok "dispatch.sh with worktree returned valid JSON"

[ -d "$ROOT/.subagents/test-wt-1/worktree" ] || err "worktree dir not created"
ok "worktree directory exists"

[ -L "$ROOT/.worktrees/test-wt-1" ] || err "worktree symlink not created"
ok "worktree symlink exists"

# Abandon the worktree task
"$ABANDON" --task-id test-wt-1 --root "$ROOT" 2>/dev/null \
  || err "subagent-abandon.sh failed"
ok "subagent-abandon.sh succeeded"

[ ! -d "$ROOT/.subagents/test-wt-1" ] || err "task dir still exists after abandon"
ok "task dir removed after abandon"

[ ! -L "$ROOT/.worktrees/test-wt-1" ] || err "worktree symlink still exists after abandon"
ok "worktree symlink removed after abandon"

# --- Test 3: run-plan.sh validates and dispatches ---

echo "test: run-plan.sh with 1-task plan..."
cat > "$ROOT/plan1.yaml" <<'YAML'
dangerously_write_trunk: true
tasks:
  - id: plan-task-1
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt.md
    target: src/foo.py
YAML

PLAN_OUT=$("$RUN_PLAN" --plan "$ROOT/plan1.yaml" 2>/dev/null) || err "run-plan.sh failed"
echo "$PLAN_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'plan_id' in d; tasks=d['tasks']; assert len(tasks)==1; assert tasks[0]['status']=='dispatched'" 2>/dev/null \
  || err "run-plan.sh JSON invalid: $PLAN_OUT"
ok "run-plan.sh returned valid JSON with dispatched task"

# Clean up plan task
"$ABANDON" --task-id plan-task-1 --root "$ROOT" 2>/dev/null || true

# --- Test 4: run-plan.sh skips task with bad worktree ---

echo "test: run-plan.sh skips task when worktree creation fails..."
# Create a branch that conflicts
git -C "$ROOT" checkout -b conflict-branch -q 2>/dev/null
git -C "$ROOT" checkout main -q 2>/dev/null

cat > "$ROOT/plan2.yaml" <<YAML
dangerously_write_trunk: true
tasks:
  - id: conflict-task
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt.md
    target: src/foo.py
    worktree: conflict-branch
YAML

PLAN_OUT2=$("$RUN_PLAN" --plan "$ROOT/plan2.yaml" 2>/dev/null) || true
echo "$PLAN_OUT2" | python3 -c "import json,sys; d=json.load(sys.stdin); tasks=d['tasks']; assert tasks[0]['status']=='skipped', f'expected skipped, got {tasks[0][\"status\"]}'" 2>/dev/null \
  || err "run-plan.sh did not skip conflicting worktree task"
ok "run-plan.sh skips task when worktree creation fails"

echo "test: all dispatch refactor checks passed"