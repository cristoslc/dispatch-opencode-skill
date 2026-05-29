#!/usr/bin/env bash
# test_poll_subagent.sh — unit + behavioral tests for poll-subagent.sh.
#
# Tests completion, stuck detection, timeout, and edge cases using
# mock task directories (no real dispatch needed).
#
# Usage: bash tests/test_poll_subagent.sh [--keep]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
POLL="$SKILL_DIR/scripts/poll-subagent.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

PASS=0; FAIL=0
ok()  { printf '  PASS %s\n' "$*"; PASS=$((PASS + 1)); }
err() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d /tmp/oc-poll-test.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "poll-test@test"
git config user.name "Poll Test"

setup_task() {
  local tid="$1"
  mkdir -p ".subagents/$tid"
  touch ".subagents/$tid/.lock"
  touch ".subagents/$tid/events.jsonl"
}

teardown_task() {
  local tid="$1"
  rm -rf ".subagents/$tid"
}

run_poll() {
  # Run poll-subagent.sh, capture exit code without triggering set -e.
  # Prints stderr to file $STDERR_FILE if set, otherwise /dev/null.
  local rc=0
  STDERR_TARGET="${STDERR_FILE:-/dev/null}"
  "$POLL" "$@" 2>"$STDERR_TARGET" || rc=$?
  echo "$rc"
}

# --- Test 1: task completes before timeout (lockfile removed) ---

echo "test: task completes before timeout..."
TASK_ID="poll-complete-1"
setup_task "$TASK_ID"
echo '{"type":"start"}' > ".subagents/$TASK_ID/events.jsonl"

# Schedule lockfile removal after brief delay
(
  sleep 2
  rm -f ".subagents/$TASK_ID/.lock"
  echo '# Output' > ".subagents/$TASK_ID/FINAL_OUTPUT.md"
) &

EXIT_CODE=$(run_poll --task-id "$TASK_ID" --root "$WORK" --interval 1 --max-polls 20 --stale-threshold 30)

if [ "$EXIT_CODE" -eq 0 ]; then ok "completed task exits 0"; else err "expected exit 0, got $EXIT_CODE"; fi

teardown_task "$TASK_ID"

# --- Test 2: task stuck (events stall past threshold) ---

echo "test: task stuck detection..."
TASK_ID="poll-stuck-1"
setup_task "$TASK_ID"
echo '{"type":"start"}' > ".subagents/$TASK_ID/events.jsonl"

# Force mtime 120s in the past so stale check triggers on second poll
python3 -c "
import os, time
path = '$WORK/.subagents/$TASK_ID/events.jsonl'
age = time.time() - 120
os.utime(path, (age, age))
"

EXIT_CODE=$(run_poll --task-id "$TASK_ID" --root "$WORK" --interval 1 --max-polls 20 --stale-threshold 5)

if [ "$EXIT_CODE" -eq 2 ]; then ok "stuck task exits 2"; else err "expected exit 2 (stuck), got $EXIT_CODE"; fi

teardown_task "$TASK_ID"

# --- Test 3: timeout (max polls reached, lockfile still present) ---

echo "test: timeout when max polls reached..."
TASK_ID="poll-timeout-1"
setup_task "$TASK_ID"

# Keep appending events so it doesn't look stuck, just never remove lockfile
(
  for i in $(seq 1 10); do
    echo "{\"type\":\"tick\",\"i\":$i}" >> ".subagents/$TASK_ID/events.jsonl"
    sleep 1
  done
) &
BG_PID=$!

EXIT_CODE=$(run_poll --task-id "$TASK_ID" --root "$WORK" --interval 1 --max-polls 3 --stale-threshold 60)

if [ "$EXIT_CODE" -eq 3 ]; then ok "timeout exits 3"; else err "expected exit 3 (timeout), got $EXIT_CODE"; fi

kill "$BG_PID" 2>/dev/null || true
wait "$BG_PID" 2>/dev/null || true
teardown_task "$TASK_ID"

# --- Test 4: error on missing task dir ---

echo "test: error on missing task dir..."
EXIT_CODE=$(run_poll --task-id nonexistent-task --root "$WORK" --interval 1 --max-polls 3)

if [ "$EXIT_CODE" -eq 1 ]; then ok "missing task dir exits 1"; else err "expected exit 1, got $EXIT_CODE"; fi

# --- Test 5: error on missing --task-id ---

echo "test: error on missing --task-id..."
EXIT_CODE=$(run_poll --root "$WORK")

if [ "$EXIT_CODE" -eq 1 ]; then ok "missing --task-id exits 1"; else err "expected exit 1, got $EXIT_CODE"; fi

# --- Test 6: error on unsafe task-id ---

echo "test: error on unsafe task-id..."
for BAD_ID in "../etc" "bad task"; do
  EXIT_CODE=$(run_poll --task-id "$BAD_ID" --root "$WORK")
  if [ "$EXIT_CODE" -eq 1 ]; then ok "unsafe task-id '$BAD_ID' rejected"; else err "unsafe task-id '$BAD_ID' should have been rejected, got $EXIT_CODE"; fi
done

# --- Test 7: progress logging to stderr ---

echo "test: progress lines logged to stderr..."
TASK_ID="poll-log-1"
setup_task "$TASK_ID"
echo '{"type":"start"}' > ".subagents/$TASK_ID/events.jsonl"

# Schedule completion
(
  sleep 2
  rm -f ".subagents/$TASK_ID/.lock"
  echo '# Done' > ".subagents/$TASK_ID/FINAL_OUTPUT.md"
) &

STDERR_FILE=$(mktemp)
EXIT_CODE=$(STDERR_FILE="$STDERR_FILE" run_poll --task-id "$TASK_ID" --root "$WORK" --interval 1 --max-polls 10 --stale-threshold 30)

if [ "$EXIT_CODE" -eq 0 ]; then ok "poll completed for logging test"; else err "poll failed for logging test: exit $EXIT_CODE"; fi

if grep -q 'poll [0-9]/10 task=poll-log-1 lines=' "$STDERR_FILE"; then
  ok "progress lines with line count appear"
else
  err "no progress lines with line count found in stderr"
fi

if grep -q 'COMPLETED' "$STDERR_FILE"; then
  ok "COMPLETED message appears"
else
  err "no COMPLETED message in stderr"
fi

rm -f "$STDERR_FILE"
teardown_task "$TASK_ID"

# --- Test 8: already completed (lockfile absent at first poll) ---

echo "test: already completed task (lockfile absent)..."
TASK_ID="poll-already-1"
setup_task "$TASK_ID"
echo '{"type":"start"}' > ".subagents/$TASK_ID/events.jsonl"

# Remove lockfile before polling starts
rm -f ".subagents/$TASK_ID/.lock"

EXIT_CODE=$(run_poll --task-id "$TASK_ID" --root "$WORK")

if [ "$EXIT_CODE" -eq 0 ]; then ok "already-completed exits 0"; else err "expected exit 0 for already-complete, got $EXIT_CODE"; fi

teardown_task "$TASK_ID"

# --- Summary ---

echo ""
echo "--- Test Summary: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ] || exit 1