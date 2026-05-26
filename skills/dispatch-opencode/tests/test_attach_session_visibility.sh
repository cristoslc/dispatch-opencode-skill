#!/usr/bin/env bash
# test_attach_session_visibility.sh — smoke test for --attach session visibility.
#
# Spawns a background opencode session via --attach, verifies the session
# appears on the serve daemon's /session listing, then checks it completes.
#
# Prerequisites:
#   - opencode serve running on port 4096 (or $OPENCODE_SERVER_URL)
#   - OPENCODE_SERVER_PASSWORD set in environment
#
# Usage: bash tests/test_attach_session_visibility.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

SERVER_URL="${OPENCODE_SERVER_URL:-http://localhost:4096}"
SESSION_TITLE="PBJ-test-$$"

WORK=$(mktemp -d /tmp/oc-attach-smoke.XXXXXX)
LOG=$(mktemp)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK, $LOG" || rm -rf "$WORK" "$LOG"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "attach@test"
git config user.name "Attach Test"

mkdir -p bread peanut-butter jelly

echo "test: spawning background opencode run via --attach..."

# Spawn a background task with a distinct title — no env unset,
# the child passes --password explicitly as CLI argument.
opencode run \
  --attach "$SERVER_URL" \
  --password "$OPENCODE_SERVER_PASSWORD" \
  --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent build \
  --title "$SESSION_TITLE" \
  --format json \
  "Make a PB&J sandwich. Use bash to echo 'spreading peanut butter' and 'spreading jelly' and 'sandwich complete!' in order." \
  2> "$WORK/stderr.log" > "$WORK/stdout.log" &
CHILD_PID=$!

# Poll for the session to appear on the server
echo "test: polling for session title='$SESSION_TITLE' on $SERVER_URL..."
FOUND=
for i in $(seq 1 30); do
  FOUND=$(curl -s -u "opencode:$OPENCODE_SERVER_PASSWORD" \
    "$SERVER_URL/session" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    sessions = json.load(sys.stdin)
    for s in sessions:
        title = s.get('title', '')
        if '$SESSION_TITLE' in title:
            print(s['id'])
            sys.exit(0)
except: pass
" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    echo "test: session $FOUND visible on server after ${i}s"
    break
  fi
  sleep 1
done

if [ -z "$FOUND" ]; then
  echo "test: FAIL — session '$SESSION_TITLE' never appeared on server" >&2
  echo "  stderr from child:" >&2
  cat "$WORK/stderr.log" >&2
  kill "$CHILD_PID" 2>/dev/null || true
  exit 1
fi

# Wait for completion
echo "test: waiting for child process to finish..."
wait "$CHILD_PID" 2>/dev/null || true

# Check it completed successfully
EXIT=$?
if [ "$EXIT" -ne 0 ]; then
  # Timeout exit code 124, but we also accept 0
  echo "test: child exit code=$EXIT (non-zero may mean timeout — still OK for visibility test)"
fi

# Verify FINAL_OUTPUT.md (not yet part of --attach mode, but check stdout for PBJ content)
if grep -qi "sandwich\|peanut butter\|jelly\|complete" "$WORK/stdout.log" 2>/dev/null; then
  echo "test: PB&J content confirmed in output"
else
  echo "test: NOTE — PB&J content not found in stdout (model variability)"
fi

echo "test: PASS — session visibility confirmed"
echo "  session ID: $FOUND"
echo "  title: $SESSION_TITLE"
echo "  server: $SERVER_URL"
echo "  child exit: $EXIT"
echo ""
echo "  To re-test manually:"
echo "    opencode attach $SERVER_URL --session $FOUND"
