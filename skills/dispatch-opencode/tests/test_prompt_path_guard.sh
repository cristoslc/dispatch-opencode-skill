#!/usr/bin/env bash
# test_prompt_path_guard.sh — test that dispatch.sh rejects prompt files
# inside .subagents/ (which would cause BSD cp "identical file" failure).
#
# Usage: bash tests/test_prompt_path_guard.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-dispatch-test.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "guard@test"
git config user.name "Guard Test"

mkdir -p src
printf 'def add(a, b): return a + b\n' > src/foo.py

ROOT="$WORK"

# --- Test 1: prompt file inside .subagents/<task-id>/ is rejected ---

echo "test: prompt inside .subagents/ is rejected..."
TASK_ID="guard-test-1"
mkdir -p ".subagents/$TASK_ID"
printf 'fix the bug' > ".subagents/$TASK_ID/prompt.md"

OUT=$("$DISPATCH" \
  --root "$ROOT" \
  --cwd "$ROOT" \
  --kind single-file-fix \
  --model ollama-cloud/deepseek-v4-flash:cloud \
  --agent build \
  --prompt-file "$ROOT/.subagents/$TASK_ID/prompt.md" \
  --target src/foo.py \
  --task-id "$TASK_ID" \
  2>&1 || true)

if echo "$OUT" | grep -q "resolves to the same path"; then
  ok "dispatch.sh rejected prompt inside .subagents/$TASK_ID/"
else
  err "expected rejection for prompt inside .subagents/, got: $OUT"
fi

rm -rf ".subagents/$TASK_ID"

# --- Test 2: prompt file outside .subagents/ still works ---

echo "test: prompt outside .subagents/ succeeds..."
printf 'fix the bug' > "$ROOT/prompt.md"

"$DISPATCH" \
  --root "$ROOT" \
  --cwd "$ROOT" \
  --kind single-file-fix \
  --model ollama-cloud/deepseek-v4-flash:cloud \
  --agent build \
  --prompt-file "$ROOT/prompt.md" \
  --target src/foo.py \
  --task-id guard-test-2 \
  2>/dev/null || err "dispatch.sh should succeed with prompt outside .subagents/"

ok "dispatch.sh succeeded with prompt outside .subagents/"

# Cleanup
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"
"$ABANDON" --task-id guard-test-2 --root "$ROOT" 2>/dev/null || true

echo "test: all prompt path guard checks passed"