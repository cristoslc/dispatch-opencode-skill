#!/usr/bin/env bash
# test_e2e_two_call.sh — E2E test: two-call pattern with real subagent.
#
# Dispatches a real subagent via run-plan.sh, does other work between
# dispatch and poll, then polls, reads output, and cleans up.
# This is the primary workflow documented in SKILL.md.

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
POLL="$SKILL_DIR/scripts/poll-subagent.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

# Create a minimal git repo (required by verify-cwd.sh)
git init "$TEST_DIR" >/dev/null 2>&1
git -C "$TEST_DIR" checkout -b feat/e2e-test >/dev/null 2>&1
git -C "$TEST_DIR" config user.email "test@test" && git -C "$TEST_DIR" config user.name "test"

mkdir -p "$TEST_DIR/prompts"
cat > "$TEST_DIR/prompts/e2e-two-call.md" <<'PROMPT'
Output the exact text "two-call pattern works" and nothing else.
PROMPT

# Create plan YAML (use headless-spike, target is a report file that exists)
touch "$TEST_DIR/report.txt"
cat > "$TEST_DIR/plan.yaml" <<'YAML'
tasks:
  - id: e2e-two-call
    kind: headless-spike
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/e2e-two-call.md
    target: report.txt
YAML

echo "=== E2E: Two-call pattern ==="

# Step 1: Dispatch (returns immediately)
echo "--- Phase 1: dispatch ---"
DISPATCH_STDERR=$(mktemp)
DISPATCH_OUTPUT=$(bash "$RUN_PLAN" --plan "$TEST_DIR/plan.yaml" 2>"$DISPATCH_STDERR") || {
  echo "  run-plan.sh stderr: $(cat "$DISPATCH_STDERR")"
  fail "run-plan.sh failed"
  echo "--- Summary: $PASS passed, $FAIL failed ---"
  exit 1
}

TASK_ID=$(echo "$DISPATCH_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['id'])" 2>/dev/null || echo "")
LOCKFILE=$(echo "$DISPATCH_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['lockfile'])" 2>/dev/null || echo "")

[ -n "$TASK_ID" ] && pass "task dispatched with id=$TASK_ID" || fail "no task id in output"
[ -f "$LOCKFILE" ] && pass "lockfile exists at dispatch time" || fail "lockfile missing at dispatch time"

# Step 2: Do other work between dispatch and poll
echo "--- Phase 2: other work ---"
# Simulate doing other work: read a file, sleep briefly
sleep 2
# Verify lockfile still exists (subagent is still running)
[ -f "$LOCKFILE" ] && pass "lockfile still present after other work" || fail "lockfile disappeared during other work"

# Step 3: Poll until completion
echo "--- Phase 3: poll ---"
POLL_EXIT=0
POLL_STDERR=$(mktemp)
bash "$POLL" --task-id "$TASK_ID" --root "$TEST_DIR" --interval 5 --max-polls 24 2>"$POLL_STDERR" || POLL_EXIT=$?

case "$POLL_EXIT" in
  0) pass "poll completed (exit 0)" ;;
  2)
    fail "poll detected stuck task (exit 2)"
    echo "  poll stderr: $(cat "$POLL_STDERR")"
    # Debug: show subagent state
    TASK_DIR="$TEST_DIR/.subagents/$TASK_ID"
    [ -f "$TASK_DIR/stderr.log" ] && echo "  subagent stderr: $(cat "$TASK_DIR/stderr.log")"
    [ -f "$TASK_DIR/stdout.log" ] && echo "  subagent stdout: $(cat "$TASK_DIR/stdout.log")"
    [ -f "$TASK_DIR/start-subagent.sh" ] && echo "  start-subagent.sh size: $(wc -c < "$TASK_DIR/start-subagent.sh")"
    [ -f "$TASK_DIR/events.jsonl" ] && echo "  events lines: $(wc -l < "$TASK_DIR/events.jsonl")"
    [ -f "$TASK_DIR/.lock" ] && echo "  lockfile exists: yes" || echo "  lockfile exists: no"
    ;;
  3)
    fail "poll timed out (exit 3)"
    echo "  poll stderr: $(cat "$POLL_STDERR")"
    ;;
  *) fail "poll failed with exit $POLL_EXIT" ;;
esac

# Step 4: Verify output
echo "--- Phase 4: verify ---"
TASK_DIR="$TEST_DIR/.subagents/$TASK_ID"
FINAL_OUTPUT="$TASK_DIR/FINAL_OUTPUT.md"

[ -f "$FINAL_OUTPUT" ] && pass "FINAL_OUTPUT.md present" || fail "FINAL_OUTPUT.md missing"
grep -qi "two-call pattern works" "$FINAL_OUTPUT" 2>/dev/null && pass "output contains expected text" || fail "expected text not found in output"

# Step 5: Cleanup
echo "--- Phase 5: cleanup ---"
bash "$CLEANUP" --task-id "$TASK_ID" --root "$TEST_DIR" 2>/dev/null && pass "cleanup succeeded" || fail "cleanup failed"
[ ! -d "$TASK_DIR" ] && pass "task dir removed" || fail "task dir still exists"

echo ""
echo "--- Summary: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ] || exit 1
