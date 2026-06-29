#!/usr/bin/env bash
# test_trunk_guard.sh — verify that dispatch to trunk (main/master) is rejected
# unless --dangerously-write-trunk is passed.
#
# Tests:
#   1. dispatch.sh on main branch fails with clear error
#   2. dispatch.sh with --dangerously-write-trunk succeeds
#   3. dispatch.sh with worktree (non-main branch) succeeds without flag
#   4. run-plan.sh on main branch fails without dangerously_write_trunk
#   5. run-plan.sh with dangerously_write_trunk: true succeeds
#
# Usage: bash tests/test_trunk_guard.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*" >&2; }

WORK=$(mktemp -d /tmp/oc-trunk-guard.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "trunk@test"
git config user.name "Trunk Guard Test"

mkdir -p src
printf 'def add(a, b):\n    return a - b\n' > src/foo.py
printf 'fix the bug\n' > prompt.md
git add -A && git commit -q -m fixture

ROOT="$WORK"

echo "=== Trunk Guard Tests ==="
echo ""

# ── Test 1: dispatch.sh on main branch fails with clear error ──

echo "--- Test 1: dispatch.sh on main is rejected ---"

OUT=$("$DISPATCH" \
  --root "$ROOT" --cwd "$ROOT" \
  --kind single-file-fix --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent build --prompt-file "$ROOT/prompt.md" \
  --target src/foo.py --task-id trunk-reject-1 \
  2>&1 || true)

if echo "$OUT" | grep -q "refusing to dispatch to trunk"; then
  ok "dispatch.sh rejected trunk with clear error message"
else
  err "expected 'refusing to dispatch to trunk' in output, got: $OUT"
fi

# ── Test 2: dispatch.sh with --dangerously-write-trunk succeeds ──

echo "--- Test 2: dispatch.sh with --dangerously-write-trunk succeeds ---"

OUT=$("$DISPATCH" \
  --root "$ROOT" --cwd "$ROOT" \
  --kind single-file-fix --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent build --prompt-file "$ROOT/prompt.md" \
  --target src/foo.py --task-id trunk-allow-1 \
  --dangerously-write-trunk \
  2>/dev/null) || { err "dispatch.sh with --dangerously-write-trunk failed"; }

echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='dispatched'" 2>/dev/null \
  && ok "dispatch.sh with --dangerously-write-trunk dispatched" \
  || err "dispatch.sh with --dangerously-write-trunk did not dispatch: $OUT"

# Clean up
"$ABANDON" --task-id trunk-allow-1 --root "$ROOT" 2>/dev/null || true

# ── Test 3: dispatch.sh with worktree succeeds without flag ──

echo "--- Test 3: dispatch.sh with worktree succeeds without flag ---"

OUT=$("$DISPATCH" \
  --root "$ROOT" --cwd "$ROOT" \
  --kind single-file-fix --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent build --prompt-file "$ROOT/prompt.md" \
  --target src/foo.py --task-id trunk-wt-1 \
  --worktree trunk-guard-test-branch \
  2>/dev/null) || { err "dispatch.sh with worktree failed"; }

echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='dispatched'" 2>/dev/null \
  && ok "dispatch.sh with worktree dispatched (bypasses trunk check)" \
  || err "dispatch.sh with worktree did not dispatch: $OUT"

# Clean up
"$ABANDON" --task-id trunk-wt-1 --root "$ROOT" 2>/dev/null || true

# ── Test 4: run-plan.sh on main fails without dangerously_write_trunk ──

echo "--- Test 4: run-plan.sh on main fails without flag ---"

cat > "$ROOT/plan-no-flag.yaml" <<'YAML'
tasks:
  - id: plan-trunk-reject
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt.md
    target: src/foo.py
YAML

OUT=$("$RUN_PLAN" --plan "$ROOT/plan-no-flag.yaml" 2>&1) || true

if echo "$OUT" | grep -q "refusing to dispatch to trunk"; then
  ok "run-plan.sh rejected trunk with clear error"
else
  err "expected 'refusing to dispatch to trunk' in run-plan output, got: $OUT"
fi

# ── Test 5: run-plan.sh with dangerously_write_trunk: true succeeds ──

echo "--- Test 5: run-plan.sh with dangerously_write_trunk: true succeeds ---"

cat > "$ROOT/plan-with-flag.yaml" <<'YAML'
dangerously_write_trunk: true
tasks:
  - id: plan-trunk-allow
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt.md
    target: src/foo.py
YAML

OUT=$("$RUN_PLAN" --plan "$ROOT/plan-with-flag.yaml" 2>/dev/null) || { err "run-plan.sh with flag failed"; }

echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); tasks=d['tasks']; assert tasks[0]['status']=='dispatched'" 2>/dev/null \
  && ok "run-plan.sh with dangerously_write_trunk:true dispatched" \
  || err "run-plan.sh with flag did not dispatch: $OUT"

# Clean up
"$ABANDON" --task-id plan-trunk-allow --root "$ROOT" 2>/dev/null || true

# ── Summary ──

echo ""
echo "=== Trunk Guard Summary: $PASS passed, $FAIL failed ==="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
