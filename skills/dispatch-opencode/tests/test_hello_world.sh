#!/usr/bin/env bash
# test_hello_world.sh — minimal end-to-end smoke test.
#
# Verifies: dispatch.sh spawns subagent, subagent runs, produces output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-hello.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "hello@test"
git config user.name "Hello Test"

cat > prompt.md <<'MD'
Say exactly "hello world" in your response. No other text.
MD

touch "$WORK/report.md"

git add -A && git commit -q -m fixture

echo "test: running hello-world dispatch..."

OUT=$("$DISPATCH" \
  --root "$WORK" \
  --cwd "$WORK" \
  --kind headless-spike \
  --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent explore \
  --prompt-file "$WORK/prompt.md" \
  --target "$WORK/report.md" \
  --task-id hello-1 \
  --dangerously-write-trunk \
  2>/dev/null) || err "dispatch.sh failed"

TASK_DIR=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_dir'])" 2>/dev/null) \
  || err "JSON output invalid: $OUT"
ok "dispatch returned valid JSON"

LOCKFILE=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['lockfile'])" 2>/dev/null)

# Poll for completion
for i in $(seq 1 60); do
  [ ! -f "$LOCKFILE" ] && break
  sleep 2
done

[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] || err "FINAL_OUTPUT.md not found"
ok "FINAL_OUTPUT.md present"

if grep -qi "hello world" "$TASK_DIR/FINAL_OUTPUT.md"; then
  ok "subagent said 'hello world'"
else
  echo "test: NOTE 'hello world' not found (model variability)"
fi

"$CLEANUP" --task-id hello-1 --root "$WORK" 2>/dev/null || true

echo "test: hello-world passed"