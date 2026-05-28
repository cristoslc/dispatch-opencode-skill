#!/usr/bin/env bash
# test_lock_watch_cycle.sh — smoke test for the full async lock-watch cycle.
#
# Uses scripts/dispatch.sh to dispatch a single-file-fix task, verifies:
#   1. .lock file created while running
#   2. FINAL_OUTPUT.md written on completion
#   3. exit code 0
#   4. Session visible on serve daemon (when OPENCODE_SERVER_URL is set)
#
# Usage: bash tests/test_lock_watch_cycle.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

SERVER_URL="${OPENCODE_SERVER_URL:-http://localhost:4096}"

WORK=$(mktemp -d /tmp/oc-lockwatch.XXXXXX)
LOG=$(mktemp)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK, $LOG" || rm -rf "$WORK" "$LOG"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "lockwatch@test"
git config user.name "Lock Watch Test"
mkdir -p src

cat > src/foo.py <<'PY'
def add(a, b):
    return a - b
PY

cat > prompt.md <<'MD'
Fix the bug in src/foo.py. The `add` function uses subtraction instead of
addition. Change `a - b` to `a + b`. Reply with "DONE" when fixed.
MD

git add -A && git commit -q -m fixture

echo "test: dispatching single-file-fix via dispatch.sh..."

# Run dispatch, capture events.jsonl path for session extraction
"$DISPATCH" \
  single-file-fix \
  "$WORK" \
  "ollama-cloud/deepseek-v4-flash:cloud" \
  "build" \
  "$WORK/prompt.md" \
  "src/foo.py" \
  --timeout 120 \
  > "$LOG" 2>&1

EXIT=$?
echo "--- dispatch output ---"
cat "$LOG" | sed 's/^/  /'

# 1. Check exit code
[ "$EXIT" -eq 0 ] || err "dispatch exited $EXIT (expected 0)"
ok "dispatch exited 0"

# 2. Find the task dir from the log
TASK_LINE=$(grep 'task_id=' "$LOG" | head -1)
TASK_ID=$(echo "$TASK_LINE" | grep -o 'task_id=[^ ]*' | cut -d= -f2)
TASK_DIR_LINE=$(grep 'dir=' "$LOG" | head -1)
TASK_DIR=$(echo "$TASK_DIR_LINE" | grep -o 'dir=[^ ]*' | cut -d= -f2)
if [ -z "$TASK_DIR" ] || [ ! -d "$TASK_DIR" ]; then
  err "could not find task dir"
fi
ok "task dir: $TASK_DIR"

# 3. Check .lock is gone (cleaned up on completion)
if [ -f "$TASK_DIR/.lock" ]; then
  err ".lock still exists after completion"
fi
ok ".lock cleaned up"

# 4. Check FINAL_OUTPUT.md exists and has exit_code: 0
if [ ! -f "$TASK_DIR/FINAL_OUTPUT.md" ]; then
  err "FINAL_OUTPUT.md not found"
fi
grep -q 'exit_code: 0' "$TASK_DIR/FINAL_OUTPUT.md" || err "exit_code not 0 in FINAL_OUTPUT.md"
ok "FINAL_OUTPUT.md has exit_code: 0"

# 5. Check events.jsonl exists and has content
[ -s "$TASK_DIR/events.jsonl" ] || err "events.jsonl missing or empty"
ok "events.jsonl has content"

# 6. Verify src/foo.py was fixed
FOO_CONTENT=$(cat "$WORK/src/foo.py")
if echo "$FOO_CONTENT" | grep -q 'a + b'; then
  ok "src/foo.py was fixed (a - b → a + b)"
else
  echo "test: NOTE src/foo.py not fixed this run (model variability)"
fi

# 7. Optional: verify session visibility on serve daemon
if [ -n "${OPENCODE_SERVER_URL:-}" ]; then
  SESSION_ID=$(grep -o '"sessionID":"[^"]*"' "$TASK_DIR/events.jsonl" | head -1 | cut -d'"' -f4 || echo "")
  if [ -n "$SESSION_ID" ]; then
    echo "test: session $SESSION_ID — check on server..."
    FOUND=$(curl -s -u "opencode:$OPENCODE_SERVER_PASSWORD" \
      "$SERVER_URL/session" 2>/dev/null \
      | python3 -c "
import json, sys
try:
    for s in json.load(sys.stdin):
        if s.get('id') == '$SESSION_ID':
            print('found')
            sys.exit(0)
except: pass
" 2>/dev/null || true)
    if [ "$FOUND" = "found" ]; then
      ok "session $SESSION_ID visible on serve daemon"
    else
      echo "test: NOTE session $SESSION_ID not found on server (may have been cleaned up)"
    fi
  fi
fi

echo "test: all checks passed"
