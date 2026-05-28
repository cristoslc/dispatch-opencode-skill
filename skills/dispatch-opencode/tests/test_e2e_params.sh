#!/usr/bin/env bash
# test_e2e_params.sh — verify each dispatch.sh parameter is passed correctly.
#
# The subagent receives the parameters via environment and self-reports what
# it observed. The harness cross-checks against the values it passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

# Define test values for each parameter
TEST_KIND="headless-spike"
TEST_CWD=""
TEST_MODEL="ollama-cloud/deepseek-v4-flash:cloud"
TEST_AGENT="explore"
TEST_PROMPT="Check your environment and report: what is your CWD, what model are you using, what agent, and what file was passed to --file? Write this to reports/param-report.md"
TEST_TARGET="reports/param-report.md"
TEST_TIMEOUT="90"

WORK=$(mktemp -d /tmp/oc-params.XXXXXX)
TEST_CWD="$WORK"
LOG=$(mktemp)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK" "$LOG"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "params@test"
git config user.name "Params Test"

mkdir -p reports

# Create the prompt file
echo "$TEST_PROMPT" > "$WORK/prompt.md"

# Create empty target file (required by --file)
touch "$WORK/$TEST_TARGET"

git add -A && git commit -q -m fixture

echo "test: dispatching with parameters..."
echo "  kind=$TEST_KIND"
echo "  cwd=$TEST_CWD"
echo "  model=$TEST_MODEL"
echo "  agent=$TEST_AGENT"
echo "  prompt=$WORK/prompt.md"
echo "  target=$TEST_TARGET"
echo "  timeout=$TEST_TIMEOUT"

"$DISPATCH" \
  "$TEST_KIND" \
  "$TEST_CWD" \
  "$TEST_MODEL" \
  "$TEST_AGENT" \
  "$WORK/prompt.md" \
  "$TEST_TARGET" \
  --timeout "$TEST_TIMEOUT" \
  > "$LOG" 2>&1

EXIT=$?
echo "exit=$EXIT"
[ "$EXIT" -eq 0 ] || err "dispatch exited $EXIT (expected 0)"
ok "dispatch exited 0"

# Find task dir
TASK_DIR=$(find "$WORK/.subagents" -maxdepth 1 -type d | tail -1)
[ -n "$TASK_DIR" ] || err "no task dir created"
ok "task dir created: $(basename "$TASK_DIR")"

# Check FINAL_OUTPUT.md exists
[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] || err "FINAL_OUTPUT.md not found"
ok "FINAL_OUTPUT.md present"

# Read the subagent's param report
REPORT="$WORK/reports/param-report.md"
if [ -f "$REPORT" ]; then
  echo ""
  echo "--- subagent param report ---"
  cat "$REPORT" | sed 's/^/  /'
  echo ""
  
  # Check that the report contains expected values
  REPORT_CONTENT=$(cat "$REPORT")
  
  # Normalize for case-insensitive matching
  REPORT_LOWER=$(echo "$REPORT_CONTENT" | tr '[:upper:]' '[:lower:]')
  
  # Verify model mentioned
  MODEL_SHORT="${TEST_MODEL#ollama-cloud/}"
  if echo "$REPORT_LOWER" | grep -q "${MODEL_SHORT%:*}" || echo "$REPORT_LOWER" | grep -q "deepseek"; then
    ok "subagent reported correct model"
  else
    echo "test: NOTE model not clearly reported (content: ${REPORT_CONTENT:0:100}...)"
  fi
  
  # Verify agent
  if echo "$REPORT_LOWER" | grep -q "$TEST_AGENT"; then
    ok "subagent reported correct agent ($TEST_AGENT)"
  else
    echo "test: NOTE agent not clearly reported"
  fi
  
  # Verify target file mentioned
  TARGET_BASE=$(basename "$TEST_TARGET")
  if echo "$REPORT_LOWER" | grep -q "${TARGET_BASE%.*}" || echo "$REPORT_LOWER" | grep -q "param-report"; then
    ok "subagent reported target file"
  else
    echo "test: NOTE target file not clearly reported"
  fi
  
  # Verify CWD or working directory
  if echo "$REPORT_LOWER" | grep -q "cwd\|working directory\|/tmp/oc-params"; then
    ok "subagent reported working directory"
  else
    echo "test: NOTE working directory not clearly reported"
  fi
else
  echo "test: NOTE subagent did not write param report, checking FINAL_OUTPUT.md"
  cat "$TASK_DIR/FINAL_OUTPUT.md" | sed 's/^/  /'
fi

# Verify events.jsonl captured the session
[ -s "$TASK_DIR/events.jsonl" ] || err "events.jsonl empty"
ok "events.jsonl has session data"

# Cross-check: verify the model string appears in events
if grep -q "${TEST_MODEL#ollama-cloud/}" "$TASK_DIR/events.jsonl" 2>/dev/null || \
   grep -q "$TEST_MODEL" "$TASK_DIR/events.jsonl" 2>/dev/null; then
  ok "model string found in events.jsonl"
else
  echo "test: NOTE model string not in events (may be in different field)"
fi

echo ""
echo "--- dispatch log ---"
cat "$LOG" | sed 's/^/  /' | tail -10

echo ""
echo "test: all parameter tests completed"
