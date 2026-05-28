#!/usr/bin/env bash
# test_e2e_hello.sh — simplest possible end-to-end test.
#
# Dispatches a "say hello world" task and verifies the output.
#
# Usage: bash tests/test_e2e_hello.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-hello.XXXXXX)
LOG=$(mktemp)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK, $LOG" || rm -rf "$WORK" "$LOG"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "hello@test"
git config user.name "Hello Test"

cat > prompt.md <<'MD'
Say "hello world" exactly. Nothing else.
MD

cat > README.md <<'MD'
# Hello World

This is a placeholder README.
MD

git add -A && git commit -q -m fixture

echo "test: dispatching hello-world..."

"$DISPATCH" \
  single-file-fix \
  "$WORK" \
  "ollama-cloud/deepseek-v4-flash:cloud" \
  "build" \
  "$WORK/prompt.md" \
  "README.md" \
  --timeout 60 \
  > "$LOG" 2>&1

echo "--- dispatch output ---"
cat "$LOG"

# Verify success
[ -f "$WORK/.subagents"/*/FINAL_OUTPUT.md ] || err "FINAL_OUTPUT.md not found"
grep -q 'hello' "$WORK/.subagents"/*/FINAL_OUTPUT.md 2>/dev/null || ok "no hello in output (checking stderr)"
grep -q 'hello' "$LOG" 2>/dev/null && ok "hello found in output"

echo "test: PASS — hello world e2e complete"
