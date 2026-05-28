#!/usr/bin/env bash
# test_hello_world.sh — minimal end-to-end smoke test.
#
# Verifies: dispatch.sh spawns subagent, subagent runs, produces output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-hello.XXXXXX)
LOG=$(mktemp)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK" "$LOG"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "hello@test"
git config user.name "Hello Test"

cat > prompt.md <<'MD'
Say exactly "hello world" in your response. No other text.
MD

# Create empty report file (required by --file)
touch "$WORK/report.md"

git add -A && git commit -q -m fixture

echo "test: running hello-world dispatch..."

"$DISPATCH" \
  headless-spike \
  "$WORK" \
  "ollama-cloud/deepseek-v4-flash:cloud" \
  "explore" \
  "$WORK/prompt.md" \
  "$WORK/report.md" \
  --timeout 60 \
  > "$LOG" 2>&1

EXIT=$?
echo "exit=$EXIT"

[ "$EXIT" -eq 0 ] || err "dispatch exited $EXIT"
ok "dispatch exited 0"

# Find task dir
TASK_DIR=$(find "$WORK/.subagents" -maxdepth 1 -type d | tail -1)
[ -n "$TASK_DIR" ] || err "no task dir created"
ok "task dir created"

[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] || err "FINAL_OUTPUT.md not found"
ok "FINAL_OUTPUT.md present"

# Check for "hello world" in output
if grep -qi "hello world" "$TASK_DIR/FINAL_OUTPUT.md"; then
  ok "subagent said 'hello world'"
else
  err "'hello world' not found in FINAL_OUTPUT.md"
fi

echo "test: hello-world passed"
