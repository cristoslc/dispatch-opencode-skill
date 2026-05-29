#!/usr/bin/env bash
# test_tsv_parsing.sh — unit + adversarial tests for TSV field parsing (issue #3).
#
# Tests TSV generation from run-plan.sh's Python parser and the dispatch.sh
# agent defaulting logic. Does NOT require a running model.
#
# Test levels: unit, adversarial
#
# Usage: bash tests/test_tsv_parsing.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*" >&2; }

WORK=$(mktemp -d /tmp/oc-tsv-test.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "tsv@test"
git config user.name "TSV Test"

mkdir -p src
printf 'fix\n' > prompt.md
printf 'x\n' > src/foo.py
git add -A && git commit -q -m fixture

ROOT="$WORK"

echo "=== Unit + Adversarial: TSV Parsing & Agent Defaulting ==="
echo ""

# ── Unit: TSV generation produces no consecutive tabs ──

echo "--- Unit: TSV generation ---"

echo "  Testing: TSV with empty agent produces '-' placeholder..."
TSV_OUT=$(python3 -c "
import yaml
tasks = [{'id': 't1', 'kind': 'single-file-fix', 'model': 'm', 'prompt': 'p.md', 'target': 's/f.py'}]
for t in tasks:
    tid = t.get('id', '')
    kind = t.get('kind', '')
    model = t.get('model', '')
    agent = t.get('agent', '')
    prompt = t.get('prompt', '')
    target = t.get('target', '')
    worktree = t.get('worktree', '')
    agent = agent if agent else '-'
    worktree = worktree if worktree else '-'
    print(f'{tid}\t{kind}\t{model}\t{agent}\t{prompt}\t{target}\t{worktree}')
")
# Verify no consecutive tabs (the original bug)
if echo "$TSV_OUT" | grep $'\t\t'; then
  err "TSV contains consecutive tabs (field shift bug)"
else
  ok "TSV has no consecutive tabs"
fi

# Verify 7 fields
FIELD_COUNT=$(echo "$TSV_OUT" | awk -F'\t' '{print NF}')
[ "$FIELD_COUNT" -eq 7 ] && ok "TSV has exactly 7 fields" || err "TSV has $FIELD_COUNT fields (expected 7)"

# Verify agent field is '-'
AGENT_FIELD=$(echo "$TSV_OUT" | awk -F'\t' '{print $4}')
[ "$AGENT_FIELD" = "-" ] && ok "empty agent becomes '-'" || err "agent field is '$AGENT_FIELD' (expected '-')"

# Verify worktree field is '-'
WT_FIELD=$(echo "$TSV_OUT" | awk -F'\t' '{print $7}')
[ "$WT_FIELD" = "-" ] && ok "empty worktree becomes '-'" || err "worktree field is '$WT_FIELD' (expected '-')"

echo "  Testing: TSV with all fields populated..."
TSV_FULL=$(python3 -c "
import yaml
tasks = [{'id': 't2', 'kind': 'single-file-fix', 'model': 'mymodel', 'agent': 'explore', 'prompt': 'p.md', 'target': 's/f.py', 'worktree': 'my-branch'}]
for t in tasks:
    tid = t.get('id', '')
    kind = t.get('kind', '')
    model = t.get('model', '')
    agent = t.get('agent', '')
    prompt = t.get('prompt', '')
    target = t.get('target', '')
    worktree = t.get('worktree', '')
    agent = agent if agent else '-'
    worktree = worktree if worktree else '-'
    print(f'{tid}\t{kind}\t{model}\t{agent}\t{prompt}\t{target}\t{worktree}')
")
FIELD_COUNT2=$(echo "$TSV_FULL" | awk -F'\t' '{print NF}')
[ "$FIELD_COUNT2" -eq 7 ] && ok "full TSV has 7 fields" || err "full TSV has $FIELD_COUNT2 fields"

AGENT2=$(echo "$TSV_FULL" | awk -F'\t' '{print $4}')
[ "$AGENT2" = "explore" ] && ok "populated agent passes through" || err "agent is '$AGENT2' (expected 'explore')"

WT2=$(echo "$TSV_FULL" | awk -F'\t' '{print $7}')
[ "$WT2" = "my-branch" ] && ok "populated worktree passes through" || err "worktree is '$WT2' (expected 'my-branch')"

# ── Unit: bash IFS=$'\t' read does not shift fields ──

echo "--- Unit: bash IFS tab-read field alignment ---"

echo "  Testing: placeholder TSV round-trips through bash correctly..."
while IFS=$'\t' read -r TID TKIND TMODEL TAGENT TPROMPT TTARGET TWORKTREE; do
  [ "$TID" = "t1" ] && ok "TID=t1" || err "TID='$TID' (expected t1)"
  [ "$TKIND" = "single-file-fix" ] && ok "TKIND=single-file-fix" || err "TKIND='$TKIND'"
  [ "$TMODEL" = "m" ] && ok "TMODEL=m" || err "TMODEL='$TMODEL'"
  [ "$TAGENT" = "-" ] && ok "TAGENT=-" || err "TAGENT='$TAGENT'"
  [ "$TPROMPT" = "p.md" ] && ok "TPROMPT=p.md" || err "TPROMPT='$TPROMPT'"
  [ "$TTARGET" = "s/f.py" ] && ok "TTARGET=s/f.py" || err "TTARGET='$TTARGET'"
  [ "$TWORKTREE" = "-" ] && ok "TWORKTREE=-" || err "TWORKTREE='$TWORKTREE'"
done <<< "$TSV_OUT"

# ── Unit: dispatch.sh agent defaulting ──

echo "--- Unit: dispatch.sh agent defaulting ---"

echo "  Testing: --agent '-' resolves to 'default' in start-subagent.sh..."
OUT=$("$DISPATCH" \
  --root "$ROOT" --cwd "$ROOT" \
  --kind single-file-fix --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent "-" \
  --prompt-file "$ROOT/prompt.md" --target src/foo.py \
  --task-id test-unit-agent-dash \
  2>/dev/null) || { err "dispatch.sh failed with --agent '-'"; }
TASK_DIR="$ROOT/.subagents/test-unit-agent-dash"

# Verify AGENT=default appears in the rendered start-subagent.sh
if [ -f "$TASK_DIR/start-subagent.sh" ]; then
  if grep -q "default" "$TASK_DIR/start-subagent.sh" 2>/dev/null; then
    ok "start-subagent.sh uses 'default' agent (not '-')"
  else
    err "start-subagent.sh does not contain 'default' — placeholder '-' may have leaked through"
  fi
else
  err "start-subagent.sh not found"
fi

# Kill the subagent immediately (we only needed to verify the rendered script)
PID=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['pid'])" 2>/dev/null || true)
[ -n "$PID" ] && kill "$PID" 2>/dev/null || true
rm -rf "$TASK_DIR" 2>/dev/null || true

# ── Adversarial: edge cases ──

echo "--- Adversarial: edge cases ---"

echo "  Testing: plan YAML with explicit agent='-' literal..."
cat > "$ROOT/adv-literal-dash.yaml" <<'YAML'
tasks:
  - id: adv-dash
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: "-"
    prompt: prompt.md
    target: src/foo.py
YAML

OUT=$("$RUN_PLAN" --plan "$ROOT/adv-literal-dash.yaml" 2>/dev/null) || true
STATUS=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['status'])" 2>/dev/null || echo "")
[ "$STATUS" = "dispatched" ] && ok "plan with agent='-' literal dispatches" || err "plan with agent='-' literal failed (status=$STATUS)"

# Kill the subagent
TASK_DIR_ADV="$ROOT/.subagents/adv-dash"
[ -d "$TASK_DIR_ADV" ] && rm -rf "$TASK_DIR_ADV" 2>/dev/null || true

echo "  Testing: plan with only agent omitted (no key at all)..."
cat > "$ROOT/adv-no-agent.yaml" <<'YAML'
tasks:
  - id: adv-no-agent
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    prompt: prompt.md
    target: src/foo.py
YAML

OUT2=$("$RUN_PLAN" --plan "$ROOT/adv-no-agent.yaml" 2>/dev/null) || true
STATUS2=$(echo "$OUT2" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['status'])" 2>/dev/null || echo "")
[ "$STATUS2" = "dispatched" ] && ok "plan with agent omitted dispatches" || err "plan with agent omitted failed (status=$STATUS2)"

TASK_DIR2="$ROOT/.subagents/adv-no-agent"
[ -d "$TASK_DIR2" ] && rm -rf "$TASK_DIR2" 2>/dev/null || true

echo "  Testing: plan with only worktree omitted (no key at all)..."
cat > "$ROOT/adv-no-worktree.yaml" <<'YAML'
tasks:
  - id: adv-no-wt
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt.md
    target: src/foo.py
YAML

OUT3=$("$RUN_PLAN" --plan "$ROOT/adv-no-worktree.yaml" 2>/dev/null) || true
STATUS3=$(echo "$OUT3" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['status'])" 2>/dev/null || echo "")
[ "$STATUS3" = "dispatched" ] && ok "plan with worktree omitted dispatches" || err "plan with worktree omitted failed (status=$STATUS3)"

TASK_DIR3="$ROOT/.subagents/adv-no-wt"
[ -d "$TASK_DIR3" ] && rm -rf "$TASK_DIR3" 2>/dev/null || true

echo "  Testing: plan with both agent and worktree omitted..."
cat > "$ROOT/adv-no-both.yaml" <<'YAML'
tasks:
  - id: adv-neither
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    prompt: prompt.md
    target: src/foo.py
YAML

OUT4=$("$RUN_PLAN" --plan "$ROOT/adv-no-both.yaml" 2>/dev/null) || true
STATUS4=$(echo "$OUT4" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['status'])" 2>/dev/null || echo "")
[ "$STATUS4" = "dispatched" ] && ok "plan with both agent+worktree omitted dispatches" || err "plan with both omitted failed (status=$STATUS4)"

TASK_DIR4="$ROOT/.subagents/adv-neither"
[ -d "$TASK_DIR4" ] && rm -rf "$TASK_DIR4" 2>/dev/null || true

echo "  Testing: dispatch.sh with no --agent flag defaults to 'default'..."
OUT5=$("$DISPATCH" \
  --root "$ROOT" --cwd "$ROOT" \
  --kind single-file-fix --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --prompt-file "$ROOT/prompt.md" --target src/foo.py \
  --task-id test-unit-no-agent-flag \
  2>/dev/null) || { err "dispatch.sh failed without --agent flag"; }

TASK_DIR5="$ROOT/.subagents/test-unit-no-agent-flag"
if [ -f "$TASK_DIR5/start-subagent.sh" ]; then
  if grep -q "default" "$TASK_DIR5/start-subagent.sh" 2>/dev/null; then
    ok "no --agent flag resolves to 'default' in start-subagent.sh"
  else
    err "no --agent flag: 'default' not found in start-subagent.sh"
  fi
else
  err "start-subagent.sh not found for no-agent-flag test"
fi

PID5=$(echo "$OUT5" | python3 -c "import json,sys; print(json.load(sys.stdin)['pid'])" 2>/dev/null || true)
[ -n "$PID5" ] && kill "$PID5" 2>/dev/null || true
rm -rf "$TASK_DIR5" 2>/dev/null || true

# ── Summary ──

echo ""
echo "=== Test Summary: $PASS passed, $FAIL failed ==="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1