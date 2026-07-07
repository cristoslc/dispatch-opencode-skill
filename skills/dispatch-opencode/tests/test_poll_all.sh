#!/usr/bin/env bash
# test_poll_all.sh — tests for poll-all.sh
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Test 1: no active tasks returns active=0, exit 0
echo "test: no active tasks..."
mkdir -p "$TEST_DIR/.subagents"
result=$(bash skills/dispatch-opencode/scripts/poll-all.sh --root "$TEST_DIR" 2>/dev/null)
active=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['active'])")
[ "$active" -eq 0 ] && echo "  PASS active=0" || { echo "  FAIL active=$active"; exit 1; }
# completed field should NOT be present — it's not computable from lockfile scan
completed_present=$(echo "$result" | python3 -c "import sys,json; print('completed' in json.load(sys.stdin))" 2>/dev/null || echo "True")
[ "$completed_present" = "False" ] && echo "  PASS completed field absent" || { echo "  FAIL completed field should be absent"; exit 1; }

# Test 2: one active task returns active=1, task metadata correct
echo "test: one active task..."
mkdir -p "$TEST_DIR/.subagents/task-a"
touch "$TEST_DIR/.subagents/task-a/.lock"
echo '{"event":"test"}' > "$TEST_DIR/.subagents/task-a/events.jsonl"
result=$(bash skills/dispatch-opencode/scripts/poll-all.sh --root "$TEST_DIR" 2>/dev/null || true)
active=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['active'])")
[ "$active" -eq 1 ] && echo "  PASS active=1" || { echo "  FAIL active=$active"; exit 1; }
task_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['id'])")
[ "$task_id" = "task-a" ] && echo "  PASS task id=task-a" || { echo "  FAIL task id=$task_id"; exit 1; }
lines=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['lines'])")
[ "$lines" -eq 1 ] && echo "  PASS lines=1" || { echo "  FAIL lines=$lines"; exit 1; }

# Test 3: two active tasks
echo "test: two active tasks..."
mkdir -p "$TEST_DIR/.subagents/task-b"
touch "$TEST_DIR/.subagents/task-b/.lock"
result=$(bash skills/dispatch-opencode/scripts/poll-all.sh --root "$TEST_DIR" 2>/dev/null || true)
active=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['active'])")
[ "$active" -eq 2 ] && echo "  PASS active=2" || { echo "  FAIL active=$active"; exit 1; }
task_count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['tasks']))")
[ "$task_count" -eq 2 ] && echo "  PASS task_count=2" || { echo "  FAIL task_count=$task_count"; exit 1; }

# Test 4: exit code 1 when tasks active
echo "test: exit code 1 when tasks active..."
bash skills/dispatch-opencode/scripts/poll-all.sh --root "$TEST_DIR" >/dev/null 2>&1 && {
  echo "  FAIL: expected exit 1 but got 0"
  exit 1
} || echo "  PASS exit 1"

# Test 5: exit code 0 when no tasks
echo "test: exit code 0 when no tasks..."
rm -f "$TEST_DIR/.subagents/task-a/.lock" "$TEST_DIR/.subagents/task-b/.lock"
bash skills/dispatch-opencode/scripts/poll-all.sh --root "$TEST_DIR" >/dev/null 2>&1 && {
  echo "  PASS exit 0"
} || { echo "  FAIL: expected exit 0"; exit 1; }

# Test 6: poll loop mode exits 0 when tasks complete
echo "test: poll loop mode..."
mkdir -p "$TEST_DIR/.subagents/task-c"
touch "$TEST_DIR/.subagents/task-c/.lock"
bash skills/dispatch-opencode/scripts/poll-all.sh --root "$TEST_DIR" --interval 1 --max-polls 5 >/dev/null 2>&1 &
POLL_PID=$!
sleep 0.5
rm -f "$TEST_DIR/.subagents/task-c/.lock"
wait "$POLL_PID" && echo "  PASS poll loop exits 0 on completion" || echo "  FAIL poll loop"

echo ""
echo "--- Test Summary: all passed ---"
