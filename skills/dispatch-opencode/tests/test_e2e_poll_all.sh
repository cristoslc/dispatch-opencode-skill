#!/usr/bin/env bash
# test_e2e_poll_all.sh — E2E test: poll-all.sh against real dispatched subagents.
#
# Dispatches 2 real subagents, calls poll-all.sh to see both active,
# waits for completion, calls poll-all.sh again to see both done.

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
POLL_ALL="$SKILL_DIR/scripts/poll-all.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

# Create a minimal git repo (required by verify-cwd.sh)
git init "$TEST_DIR" >/dev/null 2>&1
git -C "$TEST_DIR" checkout -b feat/e2e-test >/dev/null 2>&1
git -C "$TEST_DIR" config user.email "test@test" && git -C "$TEST_DIR" config user.name "test"

# Create prompt files
mkdir -p "$TEST_DIR/prompts"
cat > "$TEST_DIR/prompts/e2e-pa-task-a.md" <<'PROMPT'
Output the exact text "task-a done" and nothing else.
PROMPT
cat > "$TEST_DIR/prompts/e2e-pa-task-b.md" <<'PROMPT'
Output the exact text "task-b done" and nothing else.
PROMPT

# Create plan YAML with 2 tasks (use headless-spike, targets must exist)
touch "$TEST_DIR/report-a.txt" "$TEST_DIR/report-b.txt"
cat > "$TEST_DIR/plan.yaml" <<'YAML'
tasks:
  - id: e2e-pa-a
    kind: headless-spike
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/e2e-pa-task-a.md
    target: report-a.txt
  - id: e2e-pa-b
    kind: headless-spike
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/e2e-pa-task-b.md
    target: report-b.txt
YAML

echo "=== E2E: poll-all.sh against real subagents ==="

# Phase 1: Dispatch both tasks
echo "--- Phase 1: dispatch 2 tasks ---"
DISPATCH_OUTPUT=$(bash "$RUN_PLAN" --plan "$TEST_DIR/plan.yaml" 2>/dev/null) || {
  fail "run-plan.sh failed"
  echo "--- Summary: $PASS passed, $FAIL failed ---"
  exit 1
}

TASK_COUNT=$(echo "$DISPATCH_OUTPUT" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['tasks']))" 2>/dev/null || echo "0")
[ "$TASK_COUNT" -eq 2 ] && pass "2 tasks dispatched" || fail "expected 2 tasks, got $TASK_COUNT"

# Phase 2: poll-all.sh while tasks are active
echo "--- Phase 2: poll-all.sh while active ---"
sleep 2
POLL_RESULT=$(bash "$POLL_ALL" --root "$TEST_DIR" 2>/dev/null || true)
ACTIVE=$(echo "$POLL_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['active'])" 2>/dev/null || echo "0")
[ "$ACTIVE" -ge 1 ] && pass "poll-all reports $ACTIVE active task(s)" || fail "poll-all reports 0 active tasks (expected >=1)"

# Phase 3: Wait for both to complete
echo "--- Phase 3: wait for completion ---"
# Poll in a loop until both are done
for i in $(seq 1 30); do
  POLL_RESULT=$(bash "$POLL_ALL" --root "$TEST_DIR" 2>/dev/null || true)
  ACTIVE=$(echo "$POLL_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['active'])" 2>/dev/null || echo "1")
  [ "$ACTIVE" -eq 0 ] && break
  sleep 5
done
[ "$ACTIVE" -eq 0 ] && pass "both tasks completed within timeout" || fail "tasks still active after timeout (active=$ACTIVE)"

# Phase 4: Verify output via FINAL_OUTPUT.md
echo "--- Phase 4: verify ---"
for tid in e2e-pa-a e2e-pa-b; do
  FINAL="$TEST_DIR/.subagents/$tid/FINAL_OUTPUT.md"
  [ -f "$FINAL" ] && pass "$tid FINAL_OUTPUT.md present" || fail "$tid FINAL_OUTPUT.md missing"
done
grep -qi "task-a done" "$TEST_DIR/.subagents/e2e-pa-a/FINAL_OUTPUT.md" 2>/dev/null && pass "task-a content correct" || fail "task-a content not found"
grep -qi "task-b done" "$TEST_DIR/.subagents/e2e-pa-b/FINAL_OUTPUT.md" 2>/dev/null && pass "task-b content correct" || fail "task-b content not found"

# Phase 5: poll-all.sh after completion (should exit 0)
echo "--- Phase 5: poll-all.sh after completion ---"
bash "$POLL_ALL" --root "$TEST_DIR" >/dev/null 2>&1 && pass "poll-all exits 0 after completion" || fail "poll-all should exit 0 after completion"

# Phase 6: Cleanup
echo "--- Phase 6: cleanup ---"
for tid in e2e-pa-a e2e-pa-b; do
  bash "$CLEANUP" --task-id "$tid" --root "$TEST_DIR" 2>/dev/null || true
done
pass "cleanup completed"

echo ""
echo "--- Summary: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ] || exit 1
