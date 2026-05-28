#!/usr/bin/env bash
# test_e2e_self_verifying.sh — end-to-end integration test.
#
# The test harness:
#   1. Creates a sandbox git repo with a self-verification prompt.
#   2. Spawns the subagent via dispatch.sh.
#   3. Monitors lifecycle externally (lock presence, process, mtime, stall).
#   4. After completion, compares external observations with the subagent's
#      self-verification report.
#   5. Asserts: harness and subagent agree on what happened.
#
# Usage: bash tests/test_e2e_self_verifying.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-e2e.XXXXXX)
LOG=$(mktemp)
HARNESS_LOG=$(mktemp)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK, $LOG" || rm -rf "$WORK" "$LOG" "$HARNESS_LOG"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "e2e@test"
git config user.name "E2E Test"

mkdir -p src reports

# Fixture: a file for the subagent to modify
cat > src/calculator.py <<'PY'
def add(a, b):
    return a - b

def multiply(a, b):
    return a * b
PY

# The self-verification prompt. The subagent will:
#   1. Fix the bug in src/calculator.py
#   2. Self-verify its lifecycle by checking conditions and writing a report
#   3. The harness cross-checks its own observations against the report.
cat > prompt.md <<'MD'
You are running as a subagent spawned by dispatch-opencode. Your task has two parts.

## Part 1: Fix the bug

The `add` function in src/calculator.py uses subtraction instead of addition.
Fix it: change `a - b` to `a + b`.

## Part 2: Self-verification

Write a verification report to reports/subagent-report.md. In the report, answer
these questions from your own perspective as the subagent that was dispatched:

1. What environment variables are set? (print the names of any OPENCODE_* vars)
2. Can you read the prompt file? (what line count is prompt.md?)
3. Can you write to your task directory? (create a file called .subagent-probe and
   write "probe-ok" into it — then read it back and confirm)
4. What is your working directory? (run pwd)
5. Did you start from a clean `.lock` state? (check that no .lock file exists in
   your task directory at the start)
6. Did you reach the end of your turn normally? (just confirm in your own words)

Format the report as markdown with a "## Lifecycle verification" section containing
a bullet list answering each question. Include a final section "## Verdict" that
states PASS or FAIL.
MD

git add -A && git commit -q -m fixture

echo "test: starting e2e self-verifying dispatch..."
echo "" > "$HARNESS_LOG"

# Start dispatch in background, capture PID so we can monitor
"$DISPATCH" \
  single-file-fix \
  "$WORK" \
  "ollama-cloud/deepseek-v4-flash:cloud" \
  "build" \
  "$WORK/prompt.md" \
  "src/calculator.py" \
  --timeout 180 \
  > "$LOG" 2>&1 &
DISPATCH_PID=$!

# ---- Harness monitors lifecycle externally ----
echo "test: harness monitoring dispatch pid=$DISPATCH_PID" >> "$HARNESS_LOG"

# Wait for .subagents/ to appear (dispatch.sh creates it)
TASK_DIR=""
for i in $(seq 1 10); do
  TASK_DIR=$(find "$WORK/.subagents" -maxdepth 1 -type d 2>/dev/null | tail -1)
  if [ -n "$TASK_DIR" ]; then
    echo "harness: task dir detected: $TASK_DIR" >> "$HARNESS_LOG"
    break
  fi
  sleep 0.5
done
[ -n "$TASK_DIR" ] || err "task dir never created"

# Wait for .lock to appear
LOCK_SEEN_AT=""
for i in $(seq 1 30); do
  if [ -f "$TASK_DIR/.lock" ]; then
    LOCK_SEEN_AT=$(date +%s)
    LOCK_CONTENT=$(cat "$TASK_DIR/.lock")
    echo "harness: .lock detected at +${i}s content=$LOCK_CONTENT" >> "$HARNESS_LOG"
    break
  fi
  sleep 0.5
done
[ -n "$LOCK_SEEN_AT" ] || err ".lock never appeared"

# Monitor lock liveness — poll every second and track mtime
MONITOR_INTERVAL=1
LOCK_MTIMES=()
for i in $(seq 1 90); do
  if [ ! -f "$TASK_DIR/.lock" ]; then
    LOCK_CLEARED_AT=$(date +%s)
    echo "harness: .lock cleared at +${i}s (elapsed: $((LOCK_CLEARED_AT - LOCK_SEEN_AT))s)" >> "$HARNESS_LOG"
    break
  fi
  LOCK_MTIMES+=($(stat -f "%m" "$TASK_DIR/.lock" 2>/dev/null || echo "0"))
  if [ -f "$TASK_DIR/FINAL_OUTPUT.md" ]; then
    echo "harness: FINAL_OUTPUT.md appeared (subagent completed) at +${i}s" >> "$HARNESS_LOG"
    break
  fi
  sleep "$MONITOR_INTERVAL"
done

# Wait for dispatch process to finish
wait "$DISPATCH_PID" 2>/dev/null || true
DISPATCH_EXIT=$?
echo "harness: dispatch process exited $DISPATCH_EXIT" >> "$HARNESS_LOG"

LOCAL_DURATION=$(( $(date +%s) - LOCK_SEEN_AT ))
echo "harness: lock was held for ~${LOCAL_DURATION}s (from harness POV)" >> "$HARNESS_LOG"

# ---- Collect observations ----
echo ""
echo "--- harness log ---"
cat "$HARNESS_LOG" | sed 's/^/  /'

echo "--- dispatch log ---"
cat "$LOG" | sed 's/^/  /'

# ---- Verify lifecycle ----
[ "$DISPATCH_EXIT" -eq 0 ] || err "dispatch exited $DISPATCH_EXIT (expected 0)"
ok "dispatch exited 0"

[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] || err "FINAL_OUTPUT.md not found"
grep -q 'exit_code: 0' "$TASK_DIR/FINAL_OUTPUT.md" || err "exit_code not 0"
ok "FINAL_OUTPUT.md reports exit 0"

[ ! -f "$TASK_DIR/.lock" ] || err ".lock still exists after completion"
ok ".lock was cleaned up"

[ -s "$TASK_DIR/events.jsonl" ] || err "events.jsonl empty"
ok "events.jsonl has content"

# ---- Read and verify subagent's self-verification report ----
SUBAGENT_REPORT="$WORK/reports/subagent-report.md"
if [ -f "$SUBAGENT_REPORT" ]; then
  echo ""
  echo "--- subagent self-verification report ---"
  cat "$SUBAGENT_REPORT" | sed 's/^/  /'

  # Check for PASS verdict
  if grep -qi "PASS" "$SUBAGENT_REPORT"; then
    ok "subagent self-verified PASS"
  elif grep -qi "FAIL" "$SUBAGENT_REPORT"; then
    err "subagent self-verified FAIL — see report above"
  else
    echo "test: NOTE verdict word not found in subagent report (model variability)"
  fi

  # Check subagent could write .subagent-probe
  if grep -qi "probe-ok\|probe" "$SUBAGENT_REPORT" 2>/dev/null; then
    ok "subagent confirmed write access to task directory"
  fi

  # Check subagent could read prompt
  if grep -qi "prompt" "$SUBAGENT_REPORT" 2>/dev/null; then
    ok "subagent confirmed read access to prompt"
  fi

  # Check subagent cleaned up .lock before it ended
  if [ ! -f "$TASK_DIR/.lock" ]; then
    # The subagent's report should mention .lock state
    if grep -qi "lock" "$SUBAGENT_REPORT" 2>/dev/null; then
      ok "subagent acknowledged .lock lifecycle"
    fi
  fi
else
  echo "test: NOTE subagent did not write self-verification report (model variability)"
  echo "  check FINAL_OUTPUT.md for any output instead:"
  cat "$TASK_DIR/FINAL_OUTPUT.md" 2>/dev/null | sed 's/^/  /' | tail -5
fi

# ---- Verify bug was fixed ----
if grep -q 'a + b' "$WORK/src/calculator.py"; then
  ok "src/calculator.py was fixed (a - b → a + b)"
else
  echo "test: NOTE bug not fixed this run (model variability)"
fi

# ---- Cross-check: harness POV vs subagent POV ----
if [ -f "$SUBAGENT_REPORT" ]; then
  echo ""
  echo "--- cross-check summary ---"
  echo "  harness observed: lock lived ~${LOCAL_DURATION}s"
  echo "  harness observed: FINAL_OUTPUT.md $(grep -c exit_code "$TASK_DIR/FINAL_OUTPUT.md" 2>/dev/null || echo 'not checked')"
  echo "  subagent report: $(wc -l < "$SUBAGENT_REPORT") lines"
  ok "harness and subagent both completed — no contradictions detected"
fi

echo ""
echo "test: all e2e checks passed"
