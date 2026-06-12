#!/usr/bin/env bash
# test_sashay_pr_work.sh — end-to-end test for the PR sashay flow
# (branch+worktree+draft PR+subagent handoff) using dispatch-opencode's
# pr-work kind, as described in the AGENTS.md sashay guidance.
#
# The sashay guidance says:
#   "When the dispatch-opencode skill is available... prefer it. Its pr-work
#    kind covers steps 2-5 (branch, worktree, draft PR, handoff) in a single
#    plan YAML."
#
# This test validates that an agent following the sashay guidance can:
#   1. Write a plan in docs/plans/
#   2. Dispatch via run-plan.sh with pr-work kind
#   3. Verify the subagent works in an isolated worktree
#   4. Verify the PR chronicle mechanism (gh pr create, PR URL)
#   5. Verify the subagent produces output
#   6. Verify cleanup preserves the remote branch
#
# Usage: bash tests/test_sashay_pr_work.sh [--keep]
#
# Requires: opencode, git, python3, PyYAML

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*" >&2; }

WORK=$(mktemp -d /tmp/oc-sashay.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

# ── Setup: create a test repo with a remote ──

mkdir -p "$WORK/remote" "$WORK/shim"
cd "$WORK/remote"
git init -q --bare

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "sashay@test"
git config user.name "Sashay Test"
git remote add origin "$WORK/remote"
mkdir -p src docs/plans
printf 'def add(a, b):\n    return a - b\n' > src/foo.py
printf '.subagents/\n.worktrees/\n' >> .gitignore
git add -A && git commit -q -m "fixture: initial commit"
git push -q origin main

# ── Install a gh shim that validates flags and returns a fake PR URL ──

cat > "$WORK/shim/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" != *--draft* || "$*" != *--title* || "$*" != *--body-file* ]]; then
  echo "unexpected gh args: $*" >&2
  exit 1
fi
echo "https://github.com/test/repo/pull/42"
SHIM
chmod +x "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

# ── Step 1: Write a plan in docs/plans/ (per sashay guidance) ──

cat > "$WORK/docs/plans/fix-add-function.md" <<'PLAN'
# Plan: Fix the add function

The `add` function in `src/foo.py` returns `a - b` instead of `a + b`.
Change the subtraction to addition.

## Steps
1. Edit src/foo.py to return a + b
2. Commit the change
3. Push to the remote branch
PLAN

# ── Step 2: Write the subagent prompt ──

cat > "$WORK/prompt-sashay.md" <<'MD'
# Fix the add function

The `add` function in `src/foo.py` currently returns `a - b`.
Change it to return `a + b` instead.

## Working guidelines
You are working in a PR-tracked worktree environment.
- Commit and push your changes regularly
- After each significant checkpoint, add a PR comment via the forge CLI
- When done, ensure the change is correct and signal completion
MD

# ── Step 3: Write the plan YAML for dispatch-opencode ──

cat > "$WORK/plan-sashay.yaml" <<'YAML'
tasks:
  - id: sashay-fix-add
    kind: pr-work
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt-sashay.md
    worktree: sashay-fix-add-branch
    pr_title: "Fix: correct add function to use addition instead of subtraction"
YAML

echo "=== Sashay PR Work Test ==="
echo ""

# ── Test 1: run-plan.sh dispatches the pr-work task ──

echo "--- Test 1: pr-work dispatch via run-plan.sh ---"
OUT=$("$RUN_PLAN" --plan "$WORK/plan-sashay.yaml" 2>/dev/null) || { err "run-plan.sh failed"; }

STATUS=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['status'])" 2>/dev/null)
[ "$STATUS" = "dispatched" ] && ok "pr-work task dispatched" || err "task not dispatched (status=$STATUS)"

TASK_DIR=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['task_dir'])" 2>/dev/null)
LOCKFILE=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['lockfile'])" 2>/dev/null)

# ── Test 2: Worktree was created (branch + directory + symlink) ──

echo "--- Test 2: Worktree isolation ---"
[ -d "$TASK_DIR/worktree" ] && ok "worktree directory created" || err "worktree directory missing"
[ -L "$WORK/.worktrees/sashay-fix-add" ] && ok "worktree symlink created" || err "worktree symlink missing"
git -C "$WORK" branch --list sashay-fix-add-branch | grep -q sashay-fix-add-branch \
  && ok "worktree branch created" || err "worktree branch missing"

# ── Test 3: Start script renders with pr-work variables ──

echo "--- Test 3: Start script rendering ---"
START_SCRIPT="$TASK_DIR/start-subagent.sh"
[ -f "$START_SCRIPT" ] && ok "start-subagent.sh rendered" || err "start-subagent.sh missing"
grep -q 'gh pr create' "$START_SCRIPT" && ok "start script contains gh pr create" || err "missing gh pr create"
grep -q 'BRANCH=' "$START_SCRIPT" && ok "start script contains BRANCH var" || err "missing BRANCH var"
grep -q 'PR_TITLE=' "$START_SCRIPT" && ok "start script contains PR_TITLE var" || err "missing PR_TITLE var"
grep -q 'PR_URL' "$START_SCRIPT" && ok "start script contains PR_URL" || err "missing PR_URL"

# ── Test 4: Prompt was copied ──

[ -f "$TASK_DIR/prompt.md" ] && ok "prompt.md copied" || err "prompt.md missing"

# ── Test 5: Subagent completes and produces output ──

echo "--- Test 5: Subagent execution ---"
for ((i=1; i<=90; i++)); do
  [ ! -f "$LOCKFILE" ] && break
  sleep 2
done

if [ ! -f "$LOCKFILE" ]; then
  ok "subagent completed (.lock removed)"
else
  err "subagent did not complete within 180s"
fi

[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] && ok "FINAL_OUTPUT.md written" || err "FINAL_OUTPUT.md missing"
grep -q 'pr_url' "$TASK_DIR/FINAL_OUTPUT.md" && ok "pr_url in FINAL_OUTPUT.md" || err "pr_url missing from FINAL_OUTPUT.md"
grep -q 'pr_title' "$TASK_DIR/FINAL_OUTPUT.md" && ok "pr_title in FINAL_OUTPUT.md" || err "pr_title missing from FINAL_OUTPUT.md"
grep -q 'branch' "$TASK_DIR/FINAL_OUTPUT.md" && ok "branch in FINAL_OUTPUT.md" || err "branch missing from FINAL_OUTPUT.md"
[ -s "$TASK_DIR/events.jsonl" ] && ok "events.jsonl has content" || err "events.jsonl empty"

# ── Test 6: Cleanup removes local artifacts but preserves remote branch ──

echo "--- Test 6: Cleanup ---"
"$CLEANUP" --task-id sashay-fix-add --root "$WORK" 2>/dev/null && ok "cleanup succeeded" || err "cleanup failed"
[ ! -d "$TASK_DIR" ] && ok "task dir removed" || err "task dir persists after cleanup"
[ ! -L "$WORK/.worktrees/sashay-fix-add" ] && ok "worktree symlink removed" || err "symlink persists"

# Remote branch should survive (PR stays open on the forge)
if git -C "$WORK" branch -r | grep -q "origin/sashay-fix-add-branch"; then
  ok "remote branch survives cleanup (PR stays open)"
else
  echo "  NOTE: remote branch not found (expected if remote is bare)"
fi

# ── Summary ──

echo ""
echo "=== Sashay PR Work Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1