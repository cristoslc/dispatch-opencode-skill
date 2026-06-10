#!/usr/bin/env bash
# test_uat_all_workflows.sh — end-to-end UAT covering all dispatch-opencode
# workflows per SKILL.md v2.0.0.
#
# Tests:
#   1. Single task via run-plan.sh (full lifecycle)
#   2. Parallelize N tasks via run-plan.sh
#   3. Worktree isolation + cleanup
#   4. subagent-abandon (kill + force cleanup)
#   5. cleanup-stale.sh (stale lock + orphaned worktree)
#   6. run-plan.sh skips task on worktree conflict
#   7. headless-spike kind via run-plan.sh
#   8. Plan YAML validation (missing required fields)
#   9. dispatch.sh unsafe task-id rejection
#
# Usage: bash tests/test_uat_all_workflows.sh [--keep]
#
# Requires: opencode, git, python3, PyYAML

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"
STALE="$SKILL_DIR/scripts/cleanup-stale.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*" >&2; }

WORK=$(mktemp -d /tmp/oc-uat.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

setup_repo() {
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q -b main
  git config --local commit.gpgsign false
  git config user.email "uat@test"
  git config user.name "UAT Test"
  mkdir -p src reports
  printf 'def add(a, b):\n    return a - b\n' > src/foo.py
  printf 'def sub(a, b):\n    return a + b\n' > src/bar.py
  printf '# spike report\n' > reports/spike.md
  printf 'Fix the bug: change a - b to a + b in the add function.\n' > prompt-fix-foo.md
  printf 'Fix the bug: change a + b to a - b in the sub function.\n' > prompt-fix-bar.md
  printf 'Report what files are in src/ and their contents.\n' > prompt-spike.md
  printf '.subagents/\n.worktrees/\n' >> .gitignore
  git add -A && git commit -q -m fixture
}

wait_for_lockfile_gone() {
  local lf="$1"
  local max="${2:-60}"
  for i in $(seq 1 "$max"); do
    [ ! -f "$lf" ] && return 0
    sleep 2
  done
  return 1
}

parse_json_field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)" 2>/dev/null
}

echo "=== UAT: dispatch-opencode v2.0.0 ==="
echo ""

# ── Test 1: Single task via run-plan.sh (full lifecycle) ──

echo "--- Test 1: Single task via run-plan.sh ---"
setup_repo

cat > plan1.yaml <<'YAML'
tasks:
  - id: fix-foo
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt-fix-foo.md
    target: src/foo.py
YAML

OUT=$("$RUN_PLAN" --plan plan1.yaml 2>/dev/null) || { err "run-plan.sh failed"; }
echo "$OUT" | parse_json_field "['tasks'][0]['status']" | grep -q dispatched \
  && ok "task dispatched" || err "task not dispatched"
LOCKFILE=$(echo "$OUT" | parse_json_field "['tasks'][0]['lockfile']")
TASK_DIR=$(echo "$OUT" | parse_json_field "['tasks'][0]['task_dir']")
PID=$(echo "$OUT" | parse_json_field "['tasks'][0]['pid']")

[ -f "$LOCKFILE" ] && ok ".lock exists while running" || err ".lock missing during run"
[ -d "$TASK_DIR" ] && ok "task dir exists" || err "task dir missing"
[ -f "$TASK_DIR/prompt.md" ] && ok "prompt.md copied" || err "prompt.md missing"
[ -f "$TASK_DIR/start-subagent.sh" ] && ok "start-subagent.sh rendered" || err "start-subagent.sh missing"

if wait_for_lockfile_gone "$LOCKFILE" 60; then
  ok "subagent completed (.lock removed)"
else
  err "subagent did not complete within 120s"
fi

[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] && ok "FINAL_OUTPUT.md written" || err "FINAL_OUTPUT.md missing"
[ -s "$TASK_DIR/events.jsonl" ] && ok "events.jsonl has content" || err "events.jsonl empty"

"$CLEANUP" --task-id fix-foo --root "$WORK" 2>/dev/null && ok "cleanup succeeded" || err "cleanup failed"
[ ! -d "$TASK_DIR" ] && ok "task dir removed" || err "task dir persists after cleanup"

# ── Test 2: Parallelize N tasks via run-plan.sh ──

echo "--- Test 2: Parallelize N tasks via run-plan.sh ---"
setup_repo

cat > plan2.yaml <<'YAML'
tasks:
  - id: fix-foo-par
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt-fix-foo.md
    target: src/foo.py
  - id: fix-bar-par
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt-fix-bar.md
    target: src/bar.py
YAML

OUT=$("$RUN_PLAN" --plan plan2.yaml 2>/dev/null) || { err "run-plan.sh failed for parallel plan"; }
TASK_COUNT=$(echo "$OUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['tasks']))" 2>/dev/null)
[ "$TASK_COUNT" -eq 2 ] && ok "2 tasks dispatched" || err "expected 2 tasks, got $TASK_COUNT"

LF1=$(echo "$OUT" | parse_json_field "['tasks'][0]['lockfile']")
LF2=$(echo "$OUT" | parse_json_field "['tasks'][1]['lockfile']")

# Wait for both
wait_for_lockfile_gone "$LF1" 90 && ok "task 1 completed" || err "task 1 did not complete"
wait_for_lockfile_gone "$LF2" 90 && ok "task 2 completed" || err "task 2 did not complete"

# Cleanup both
"$CLEANUP" --task-id fix-foo-par --root "$WORK" 2>/dev/null && ok "task 1 cleanup" || err "task 1 cleanup failed"
"$CLEANUP" --task-id fix-bar-par --root "$WORK" 2>/dev/null && ok "task 2 cleanup" || err "task 2 cleanup failed"

# ── Test 3: Worktree isolation + cleanup ──

echo "--- Test 3: Worktree isolation + cleanup ---"
setup_repo

OUT=$("$DISPATCH" \
  --root "$WORK" --cwd "$WORK" \
  --kind single-file-fix --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent build --prompt-file "$WORK/prompt-fix-foo.md" \
  --target src/foo.py --task-id wt-test \
  --worktree wt-test-branch 2>/dev/null) || { err "dispatch with worktree failed"; }
WT=$(echo "$OUT" | parse_json_field "['worktree']")
[ "$WT" != "None" ] && [ -n "$WT" ] && ok "worktree in JSON" || err "worktree missing from JSON"
[ -d "$WORK/.subagents/wt-test/worktree" ] && ok "worktree dir exists" || err "worktree dir missing"
[ -L "$WORK/.worktrees/wt-test" ] && ok "worktree symlink exists" || err "worktree symlink missing"

# Verify branch exists
git -C "$WORK" branch --list wt-test-branch | grep -q wt-test-branch \
  && ok "worktree branch created" || err "worktree branch missing"

LOCKFILE=$(echo "$OUT" | parse_json_field "['lockfile']")
wait_for_lockfile_gone "$LOCKFILE" 60 || true

# Cleanup worktree
"$CLEANUP" --task-id wt-test --root "$WORK" 2>/dev/null && ok "worktree cleanup succeeded" || err "worktree cleanup failed"
[ ! -d "$WORK/.subagents/wt-test" ] && ok "task dir removed" || err "task dir persists"
[ ! -L "$WORK/.worktrees/wt-test" ] && ok "symlink removed" || err "symlink persists"

# ── Test 4: subagent-abandon (kill + force cleanup) ──

echo "--- Test 4: subagent-abandon ---"
setup_repo

# Dispatch a task that will take a while (worktree variant)
OUT=$("$DISPATCH" \
  --root "$WORK" --cwd "$WORK" \
  --kind single-file-fix --model "ollama-cloud/deepseek-v4-flash:cloud" \
  --agent build --prompt-file "$WORK/prompt-fix-foo.md" \
  --target src/foo.py --task-id abandon-test \
  --worktree abandon-test-branch 2>/dev/null) || { err "dispatch for abandon test failed"; }
TASK_DIR="$WORK/.subagents/abandon-test"
[ -d "$TASK_DIR" ] && ok "task dir exists before abandon" || err "task dir missing before abandon"
[ -L "$WORK/.worktrees/abandon-test" ] && ok "worktree symlink before abandon" || err "worktree symlink missing"

"$ABANDON" --task-id abandon-test --root "$WORK" 2>/dev/null && ok "abandon succeeded" || err "abandon failed"
[ ! -d "$TASK_DIR" ] && ok "task dir removed after abandon" || err "task dir persists after abandon"
[ ! -L "$WORK/.worktrees/abandon-test" ] && ok "worktree symlink removed after abandon" || err "symlink persists"
git -C "$WORK" branch --list abandon-test-branch | grep -q abandon-test-branch \
  && err "branch still exists after abandon" || ok "branch deleted after abandon"

# ── Test 5: cleanup-stale.sh ──

echo "--- Test 5: cleanup-stale.sh ---"
setup_repo

# Create a stale lock (dead PID)
mkdir -p "$WORK/.subagents/stale-task"
echo "PID=999999999" > "$WORK/.subagents/stale-task/.lock"

# Create a task dir with no lock (orphaned worktree symlink)
mkdir -p "$WORK/.worktrees"
ln -sf "$WORK/.subagents/orphan-wt/worktree" "$WORK/.worktrees/orphan-wt"

OUT=$("$STALE" "$WORK" 2>/dev/null) || true
echo "$OUT" | grep -q "stale-task" && ok "stale lock detected" || err "stale lock not detected"
echo "$OUT" | grep -qi "orphan" && ok "orphaned worktree detected" || err "orphaned worktree not detected"

# Test --abandon flag
mkdir -p "$WORK/.subagents/stale-task2"
echo "PID=999999998" > "$WORK/.subagents/stale-task2/.lock"
"$STALE" --abandon "$WORK" 2>/dev/null || true
[ ! -f "$WORK/.subagents/stale-task2/.lock" ] && ok "stale lock cleaned by --abandon" || err "stale lock persists after --abandon"

# Test --dry-run
mkdir -p "$WORK/.subagents/stale-task3"
echo "PID=999999997" > "$WORK/.subagents/stale-task3/.lock"
"$STALE" --dry-run "$WORK" 2>/dev/null || true
[ -f "$WORK/.subagents/stale-task3/.lock" ] && ok "dry-run does not remove" || err "dry-run removed a lock"

# Clean up stale fixtures
rm -rf "$WORK/.subagents/stale-task" "$WORK/.subagents/stale-task3" "$WORK/.worktrees/orphan-wt"

# ── Test 6: run-plan.sh skips task on worktree conflict ──

echo "--- Test 6: run-plan.sh skips task on worktree conflict ---"
setup_repo

git -C "$WORK" checkout -b conflict-branch -q 2>/dev/null
git -C "$WORK" checkout main -q 2>/dev/null

cat > plan6.yaml <<YAML
tasks:
  - id: conflict-task
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt-fix-foo.md
    target: src/foo.py
    worktree: conflict-branch
YAML

OUT=$("$RUN_PLAN" --plan plan6.yaml 2>/dev/null) || true
STATUS=$(echo "$OUT" | parse_json_field "['tasks'][0]['status']" 2>/dev/null || echo "")
[ "$STATUS" = "skipped" ] && ok "task skipped on worktree conflict" || err "task not skipped (status=$STATUS)"

# ── Test 7: headless-spike kind via run-plan.sh ──

echo "--- Test 7: headless-spike via run-plan.sh ---"
setup_repo

cat > plan7.yaml <<'YAML'
tasks:
  - id: spike-1
    kind: headless-spike
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: explore
    prompt: prompt-spike.md
    target: reports/spike.md
YAML

OUT=$("$RUN_PLAN" --plan plan7.yaml 2>/dev/null) || { err "headless-spike run-plan failed"; }
STATUS=$(echo "$OUT" | parse_json_field "['tasks'][0]['status']")
[ "$STATUS" = "dispatched" ] && ok "headless-spike dispatched" || err "headless-spike not dispatched (status=$STATUS)"

LOCKFILE=$(echo "$OUT" | parse_json_field "['tasks'][0]['lockfile']")
TASK_DIR=$(echo "$OUT" | parse_json_field "['tasks'][0]['task_dir']")

wait_for_lockfile_gone "$LOCKFILE" 90 && ok "spike completed" || err "spike did not complete"
[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] && ok "spike FINAL_OUTPUT.md present" || err "spike FINAL_OUTPUT.md missing"

"$CLEANUP" --task-id spike-1 --root "$WORK" 2>/dev/null || true

# ── Test 8: Plan YAML validation (missing required fields) ──

echo "--- Test 8: Plan YAML validation ---"
setup_repo

# Missing id
cat > plan8a.yaml <<'YAML'
tasks:
  - kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    prompt: prompt-fix-foo.md
    target: src/foo.py
YAML
"$RUN_PLAN" --plan plan8a.yaml 2>/dev/null && err "accepted plan with missing id" || ok "rejected plan with missing id"

# Missing kind
cat > plan8b.yaml <<'YAML'
tasks:
  - id: no-kind
    model: ollama-cloud/deepseek-v4-flash:cloud
    prompt: prompt-fix-foo.md
    target: src/foo.py
YAML
"$RUN_PLAN" --plan plan8b.yaml 2>/dev/null && err "accepted plan with missing kind" || ok "rejected plan with missing kind"

# Missing model
cat > plan8c.yaml <<'YAML'
tasks:
  - id: no-model
    kind: single-file-fix
    prompt: prompt-fix-foo.md
    target: src/foo.py
YAML
"$RUN_PLAN" --plan plan8c.yaml 2>/dev/null && err "accepted plan with missing model" || ok "rejected plan with missing model"

# Missing prompt
cat > plan8d.yaml <<'YAML'
tasks:
  - id: no-prompt
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    target: src/foo.py
YAML
"$RUN_PLAN" --plan plan8d.yaml 2>/dev/null && err "accepted plan with missing prompt" || ok "rejected plan with missing prompt"

# Empty tasks
cat > plan8e.yaml <<'YAML'
tasks: []
YAML
"$RUN_PLAN" --plan plan8e.yaml 2>/dev/null && err "accepted empty tasks" || ok "rejected empty tasks"

# Nonexistent plan file
"$RUN_PLAN" --plan nonexistent.yaml 2>/dev/null && err "accepted nonexistent plan" || ok "rejected nonexistent plan"

# ── Test 9: dispatch.sh unsafe task-id rejection ──

echo "--- Test 9: Unsafe task-id rejection ---"
setup_repo

"$DISPATCH" --root "$WORK" --cwd "$WORK" --kind single-file-fix \
  --model "ollama-cloud/deepseek-v4-flash:cloud" --agent build \
  --prompt-file "$WORK/prompt-fix-foo.md" --target src/foo.py \
  --task-id "../../../etc/passwd" 2>/dev/null \
  && err "accepted path traversal task-id" || ok "rejected path traversal task-id"

"$DISPATCH" --root "$WORK" --cwd "$WORK" --kind single-file-fix \
  --model "ollama-cloud/deepseek-v4-flash:cloud" --agent build \
  --prompt-file "$WORK/prompt-fix-foo.md" --target src/foo.py \
  --task-id "task with spaces" 2>/dev/null \
  && err "accepted task-id with spaces" || ok "rejected task-id with spaces"

"$DISPATCH" --root "$WORK" --cwd "$WORK" --kind single-file-fix \
  --model "ollama-cloud/deepseek-v4-flash:cloud" --agent build \
  --prompt-file "$WORK/prompt-fix-foo.md" --target src/foo.py \
  --task-id "" 2>/dev/null \
  && err "accepted empty task-id" || ok "rejected empty task-id"

# ── Summary ──

echo ""
echo "=== UAT Summary: $PASS passed, $FAIL failed ==="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
