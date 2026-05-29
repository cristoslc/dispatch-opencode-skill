#!/usr/bin/env bash
# test_empty_agent_field.sh — verify issue #3: TSV parsing with empty agent field.
#
# When a plan YAML omits the agent field, run-plan.sh must still produce
# correct TSV (with placeholder) and dispatch.sh must accept it.
#
# Tests:
#   1. run-plan.sh dispatches a task with no agent field
#   2. dispatch.sh accepts empty agent (defaults to "default")
#   3. run-plan.sh with multi-task plan mixing empty and non-empty agents
#
# Usage: bash tests/test_empty_agent_field.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-empty-agent.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "emptyagent@test"
git config user.name "Empty Agent Test"

mkdir -p src
printf 'def add(a, b):\n    return a - b\n' > src/foo.py
printf 'fix the bug\n' > prompt.md
git add -A && git commit -q -m fixture

ROOT="$WORK"

# --- Test 1: run-plan.sh dispatches task with no agent field ---

echo "test: run-plan.sh with no agent field..."
cat > "$ROOT/plan-no-agent.yaml" <<'YAML'
tasks:
  - id: no-agent-1
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    prompt: prompt.md
    target: src/foo.py
YAML

PLAN_OUT=$("$RUN_PLAN" --plan "$ROOT/plan-no-agent.yaml" 2>/dev/null) || err "run-plan.sh failed with no agent field"
echo "$PLAN_OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
tasks = d['tasks']
assert len(tasks) == 1, f'expected 1 task, got {len(tasks)}'
assert tasks[0]['status'] == 'dispatched', f'expected dispatched, got {tasks[0][\"status\"]}'
" 2>/dev/null || err "run-plan.sh did not dispatch task with missing agent: $PLAN_OUT"
ok "run-plan.sh dispatches task with no agent field"

# Clean up
"$ABANDON" --task-id no-agent-1 --root "$ROOT" 2>/dev/null || true

# --- Test 2: dispatch.sh accepts empty agent (placeholder "-") ---

echo "test: dispatch.sh with --agent '-' placeholder..."
OUT=$("$DISPATCH" \
  --root "$ROOT" \
  --cwd "$ROOT" \
  --kind single-file-fix \
  --model ollama-cloud/deepseek-v4-flash:cloud \
  --agent "-" \
  --prompt-file "$ROOT/prompt.md" \
  --target src/foo.py \
  --task-id test-empty-agent \
  2>/dev/null) || err "dispatch.sh failed with --agent '-'"

echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='dispatched'" 2>/dev/null \
  || err "dispatch.sh JSON invalid with empty agent: $OUT"
ok "dispatch.sh accepts --agent '-' placeholder"

# Clean up
"$ABANDON" --task-id test-empty-agent --root "$ROOT" 2>/dev/null || true

# --- Test 3: multi-task plan mixing empty and non-empty agents ---

echo "test: run-plan.sh with mixed agent fields..."
cat > "$ROOT/plan-mixed.yaml" <<'YAML'
tasks:
  - id: has-agent
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: explore
    prompt: prompt.md
    target: src/foo.py
  - id: no-agent-2
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    prompt: prompt.md
    target: src/foo.py
YAML

PLAN_OUT2=$("$RUN_PLAN" --plan "$ROOT/plan-mixed.yaml" 2>/dev/null) || err "run-plan.sh failed with mixed agent fields"
echo "$PLAN_OUT2" | python3 -c "
import json, sys
d = json.load(sys.stdin)
tasks = d['tasks']
assert len(tasks) == 2, f'expected 2 tasks, got {len(tasks)}'
for t in tasks:
    assert t['status'] == 'dispatched', f'task {t[\"id\"]} not dispatched: {t[\"status\"]}'
" 2>/dev/null || err "run-plan.sh did not dispatch all tasks in mixed plan: $PLAN_OUT2"
ok "run-plan.sh dispatches all tasks in mixed plan"

# Clean up
"$ABANDON" --task-id has-agent --root "$ROOT" 2>/dev/null || true
"$ABANDON" --task-id no-agent-2 --root "$ROOT" 2>/dev/null || true

echo ""
echo "test: all empty-agent-field tests passed"