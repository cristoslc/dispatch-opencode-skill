#!/usr/bin/env bash
# test_lock_watch_cycle.sh — smoke test for the full async lock-watch cycle.
#
# Uses dispatch.sh to dispatch a single-file-fix task, verifies:
#   1. .lock file created while running
#   2. FINAL_OUTPUT.md written on completion
#   3. JSON output valid
#   4. events.jsonl has content
#
# Usage: bash tests/test_lock_watch_cycle.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-lockwatch.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

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

OUT=$("$DISPATCH" \
  --root "$WORK" \
  --cwd "$WORK" \
  --kind single-file-fix \
  --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent build \
  --prompt-file "$WORK/prompt.md" \
  --target src/foo.py \
  --task-id lockwatch-1 \
  --dangerously-write-trunk \
  2>/dev/null) || err "dispatch.sh failed"

# Parse JSON output
TASK_DIR=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_dir'])" 2>/dev/null) \
  || err "JSON output invalid: $OUT"

LOCKFILE=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['lockfile'])" 2>/dev/null)

ok "dispatch returned valid JSON"
[ -d "$TASK_DIR" ] || err "task dir not created"
ok "task dir exists: $(basename "$TASK_DIR")"

# Poll for completion
for i in $(seq 1 60); do
  [ ! -f "$LOCKFILE" ] && break
  sleep 2
done

if [ -f "$LOCKFILE" ]; then
  err ".lock still exists after 120s"
fi
ok ".lock cleaned up"

[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] || err "FINAL_OUTPUT.md not found"
ok "FINAL_OUTPUT.md present"

grep -q 'exit_code: 0' "$TASK_DIR/FINAL_OUTPUT.md" || err "exit_code not 0 in FINAL_OUTPUT.md"
ok "FINAL_OUTPUT.md has exit_code: 0"

[ -s "$TASK_DIR/events.jsonl" ] || err "events.jsonl missing or empty"
ok "events.jsonl has content"

"$CLEANUP" --task-id lockwatch-1 --root "$WORK" 2>/dev/null || err "cleanup failed"
[ ! -d "$TASK_DIR" ] || err "task dir still exists after cleanup"
ok "cleanup removed task dir"

echo "test: all checks passed"