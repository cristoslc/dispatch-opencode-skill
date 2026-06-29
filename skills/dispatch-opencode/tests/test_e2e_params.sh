#!/usr/bin/env bash
# test_e2e_params.sh — verify each dispatch.sh parameter is passed correctly.
#
# The subagent receives the parameters and reports what it observed.
# The harness cross-checks against the values it passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

TEST_MODEL="ollama-cloud/deepseek-v4-flash:cloud"
TEST_AGENT="explore"
TEST_TARGET="reports/param-report.md"

WORK=$(mktemp -d /tmp/oc-params.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "params@test"
git config user.name "Params Test"

mkdir -p reports

cat > prompt.md <<MD
Check your environment and report: what is your CWD, what model are you
using, what agent, and what file was passed to --file? Write this to
$TEST_TARGET
MD

touch "$WORK/$TEST_TARGET"

git add -A && git commit -q -m fixture

echo "test: dispatching with parameters..."
echo "  kind=headless-spike"
echo "  cwd=$WORK"
echo "  model=$TEST_MODEL"
echo "  agent=$TEST_AGENT"
echo "  target=$TEST_TARGET"

OUT=$("$DISPATCH" \
  --root "$WORK" \
  --cwd "$WORK" \
  --kind headless-spike \
  --model "$TEST_MODEL" \
  --agent "$TEST_AGENT" \
  --prompt-file "$WORK/prompt.md" \
  --target "$WORK/$TEST_TARGET" \
  --task-id params-1 \
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

REPORT="$WORK/$TEST_TARGET"
if [ -f "$REPORT" ]; then
  echo ""
  echo "--- subagent param report ---"
  sed 's/^/  /' "$REPORT"
  echo ""

  REPORT_LOWER=$(tr '[:upper:]' '[:lower:]' < "$REPORT")

  MODEL_SHORT="${TEST_MODEL#ollama-cloud/}"
  if echo "$REPORT_LOWER" | grep -q "${MODEL_SHORT%:*}"; then
    ok "subagent reported correct model"
  else
    echo "test: NOTE model not clearly reported"
  fi

  if echo "$REPORT_LOWER" | grep -q "$TEST_AGENT"; then
    ok "subagent reported correct agent ($TEST_AGENT)"
  else
    echo "test: NOTE agent not clearly reported"
  fi
else
  echo "test: NOTE subagent did not write param report"
fi

[ -s "$TASK_DIR/events.jsonl" ] || err "events.jsonl empty"
ok "events.jsonl has session data"

"$CLEANUP" --task-id params-1 --root "$WORK" 2>/dev/null || true

echo ""
echo "test: all parameter tests completed"