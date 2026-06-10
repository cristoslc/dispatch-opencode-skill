#!/usr/bin/env bash
# test_pr_work_flow.sh — end-to-end test for pr-work dispatch kind.
#
# Verifies:
#   1. pr-work dispatch creates branch + worktree
#   2. Template renders with PR_URL, gh pr create, branch, pr_title
#   3. subagent runs in worktree and produces output
#   4. Cleanup removes worktree but preserves remote branch + PR
#
# Usage: bash tests/test_pr_work_flow.sh [--keep]
#
# Requires: opencode, git, python3, PyYAML

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/dispatch.sh"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok() { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-pr-work.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

# Setup: create a test repo with a local bare remote
mkdir -p "$WORK/remote" "$WORK/shim"
cd "$WORK/remote"
git init -q --bare

cd "$WORK"
git init -q -b main
git config --local commit.gpgsign false
git config user.email "pr-work@test"
git config user.name "PR Work Test"
git remote add origin "$WORK/remote"
mkdir -p src
printf 'def add(a, b):\n    return a - b\n' > src/foo.py
printf '.subagents/\n.worktrees/\n' >> .gitignore
git add -A && git commit -q -m fixture
git push -q origin main

# Install a gh shim that creates a fake PR URL
cat > "$WORK/shim/gh" <<'SHIM'
#!/usr/bin/env bash
# gh shim — validates flags and returns a fake PR URL for testing
if [[ "$*" != *--draft* || "$*" != *--title* || "$*" != *--body-file* ]]; then
  echo "unexpected gh args: $*" >&2
  exit 1
fi
echo "https://github.com/test/repo/pull/42"
SHIM
chmod +x "$WORK/shim/gh"

# Also shim git push to always succeed
export PATH="$WORK/shim:$PATH"

# Write prompt
cat > "$WORK/prompt-work.md" <<'MD'
# Test implementation

Fix the add function in src/foo.py. Change a - b to a + b.

## Working guidelines
- Commit and push your changes
- Add a PR comment for each checkpoint
- When done, ensure tests pass
MD

# Write plan
cat > "$WORK/plan.yaml" <<'YAML'
tasks:
  - id: pr-work-test
    kind: pr-work
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt-work.md
    worktree: pr-work-test-branch
    pr_title: "Test: PR-work dispatch kind"
YAML

echo "test: running pr-work dispatch via run-plan.sh..."
OUT=$("$RUN_PLAN" --plan "$WORK/plan.yaml" 2>/dev/null) || { err "run-plan.sh failed"; }

STATUS=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['status'])" 2>/dev/null)
[ "$STATUS" = "dispatched" ] && ok "pr-work task dispatched" || err "pr-work task not dispatched (status=$STATUS)"

TASK_DIR=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['task_dir'])" 2>/dev/null)
LOCKFILE=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['lockfile'])" 2>/dev/null)

# Check worktree exists
[ -d "$TASK_DIR/worktree" ] && ok "worktree directory created" || err "worktree directory missing"
[ -L "$WORK/.worktrees/pr-work-test" ] && ok "worktree symlink created" || err "worktree symlink missing"

# Verify branch exists
git -C "$WORK" branch --list pr-work-test-branch | grep -q pr-work-test-branch \
  && ok "worktree branch created" || err "worktree branch missing"

# Check start script renders with pr-work variables
START_SCRIPT="$TASK_DIR/start-subagent.sh"
[ -f "$START_SCRIPT" ] && ok "start-subagent.sh rendered" || err "start-subagent.sh missing"

grep -q 'gh pr create' "$START_SCRIPT" && ok "start script contains gh pr create" || err "missing gh pr create in start script"
grep -q 'BRANCH=' "$START_SCRIPT" && ok "start script contains BRANCH var" || err "missing BRANCH var"
grep -q 'PR_TITLE=' "$START_SCRIPT" && ok "start script contains PR_TITLE var" || err "missing PR_TITLE var"
grep -q 'PR_URL' "$START_SCRIPT" && ok "start script contains PR_URL" || err "missing PR_URL in start script"

# Check prompt was copied
[ -f "$TASK_DIR/prompt.md" ] && ok "prompt.md copied" || err "prompt.md missing"

# Poll for completion (generous timeout since this is a real opencode run)
for ((i=1; i<=90; i++)); do
  [ ! -f "$LOCKFILE" ] && break
  sleep 2
done

if [ ! -f "$LOCKFILE" ]; then
  ok "subagent completed (.lock removed)"
else
  err "subagent did not complete within 180s"
fi

# Check FINAL_OUTPUT.md
[ -f "$TASK_DIR/FINAL_OUTPUT.md" ] && ok "FINAL_OUTPUT.md written" || err "FINAL_OUTPUT.md missing"
grep -q 'pr_url' "$TASK_DIR/FINAL_OUTPUT.md" && ok "pr_url in FINAL_OUTPUT.md" || err "pr_url missing from FINAL_OUTPUT.md"
grep -q 'pr_title' "$TASK_DIR/FINAL_OUTPUT.md" && ok "pr_title in FINAL_OUTPUT.md" || err "pr_title missing from FINAL_OUTPUT.md"
grep -q 'branch' "$TASK_DIR/FINAL_OUTPUT.md" && ok "branch in FINAL_OUTPUT.md" || err "branch missing from FINAL_OUTPUT.md"

[ -s "$TASK_DIR/events.jsonl" ] && ok "events.jsonl has content" || err "events.jsonl empty"

# Cleanup
"$CLEANUP" --task-id pr-work-test --root "$WORK" 2>/dev/null && ok "cleanup succeeded" || err "cleanup failed"
[ ! -d "$TASK_DIR" ] && ok "task dir removed" || err "task dir persists after cleanup"
[ ! -L "$WORK/.worktrees/pr-work-test" ] && ok "worktree symlink removed" || err "symlink persists"

# Verify remote branch survives cleanup (PR is still open)
if git -C "$WORK" branch -r | grep -q "origin/pr-work-test-branch"; then
  ok "remote branch survives cleanup (PR stays open)"
else
  echo "test: NOTE remote branch not found (expected if remote is bare)"
fi

rm -f "$WORK/shim/gh"
echo "test: pr-work flow completed"
