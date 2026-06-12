#!/usr/bin/env bash
# test_agent_sashay_invocation.sh — agent integration test for dispatch-opencode
# invocability from a sashay-style calling agent.
#
# This test spawns a real opencode session as the "calling agent" and gives it
# a task-level prompt with sashay context (branch and PR already exist). The
# agent must discover the correct dispatch mechanism from the globally-installed
# skill — no SKILL.md concatenation, no step-by-step instructions.
#
# It measures COMPLIANCE: does the agent correctly invoke dispatch-opencode's
# pr-work kind when given sashay context? Non-deterministic by nature — run
# N times and measure pass rate.
#
# The sashay context (branch, draft PR) is set up before the agent runs,
# mirroring what a real orchestrator would have already done. The agent's job
# is to dispatch the subagent portion.
#
# Checklist (each scored per run):
#   C1: Plan YAML file created (snapshot before cleanup)
#   C2: Plan YAML has kind: pr-work
#   C3: Plan YAML has worktree field
#   C4: Plan YAML has prompt field pointing to an existing file
#   C5: Plan YAML has model field
#   C6: .subagents/<task-id> directory exists (dispatch happened)
#   C7: start-subagent.sh contains gh pr create (PR creation)
#   C8: Worktree branch was created
#   C9: .subagents/<task-id>/prompt.md exists
#
# Usage:
#   bash tests/test_agent_sashay_invocation.sh          # single run
#   bash tests/test_agent_sashay_invocation.sh -n 5     # 5 runs, measure compliance
#   bash tests/test_agent_sashay_invocation.sh --keep    # keep temp dirs on failure
#
# Requires: opencode, git, python3, PyYAML

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_PLAN="$SKILL_DIR/scripts/run-plan.sh"
CLEANUP="$SKILL_DIR/scripts/subagent-cleanup.sh"
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"

N=1
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) shift; N="${1:-1}"; shift ;;
    --keep) KEEP=1; shift ;;
    *) shift ;;
  esac
done

PASS_TOTAL=0
FAIL_TOTAL=0
CHECKLIST_TOTAL=0
RUNS=0

# Checklist counters per criterion
C1_PASS=0; C1_FAIL=0
C2_PASS=0; C2_FAIL=0
C3_PASS=0; C3_FAIL=0
C4_PASS=0; C4_FAIL=0
C5_PASS=0; C5_FAIL=0
C6_PASS=0; C6_FAIL=0
C7_PASS=0; C7_FAIL=0
C8_PASS=0; C8_FAIL=0
C9_PASS=0; C9_FAIL=0

check() {
  local label="$1" result="$2"
  CHECKLIST_TOTAL=$((CHECKLIST_TOTAL + 1))
  if [ "$result" = "0" ]; then
    PASS_TOTAL=$((PASS_TOTAL + 1))
    eval "${label}_PASS=$((${label}_PASS + 1))"
  else
    FAIL_TOTAL=$((FAIL_TOTAL + 1))
    eval "${label}_FAIL=$((${label}_FAIL + 1))"
  fi
}

run_once() {
  local run_num="$1"
  local WORK
  WORK=$(mktemp -d "/tmp/oc-sashay-agent.${run_num}.XXXXXX")

  echo ""
  echo "=== Run $run_num: $WORK ==="

  # ── Setup: git repo with fixture ──
  mkdir -p "$WORK/remote" "$WORK/shim"
  git init -q --bare "$WORK/remote"

  cd "$WORK"
  git init -q -b main
  git config --local commit.gpgsign false
  git config user.email "sashay-agent@test"
  git config user.name "Sashay Agent Test"
  git remote add origin "$WORK/remote"
  mkdir -p src prompts
  printf 'def add(a, b):\n    return a - b\n' > src/foo.py
  printf '.subagents/\n.worktrees/\n' >> .gitignore
  git add -A && git commit -q -m "fixture: initial commit"
  git push -q origin main

  # ── Sashay context: orchestrator has created branch + draft PR ──
  SASHAY_BRANCH="fix-add-sashay"
  SASHAY_PR_URL="https://github.com/test/repo/pull/42"
  git checkout -q -b "$SASHAY_BRANCH"
  git push -q origin "$SASHAY_BRANCH" 2>/dev/null || true
  git checkout -q main

  # ── gh shim ──
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

  # ── Prompt: task-level description with sashay context ──
  # The orchestrator has started a sashay — branch and PR exist.
  # The agent must discover the correct dispatch mechanism from the skill.

  cat > "$WORK/calling-agent-prompt.md" <<PROMPT
Fix the bug in src/foo.py: the add() function returns a - b instead of a + b.

A sashay has been started for this fix:
- Branch: ${SASHAY_BRANCH}
- Draft PR: ${SASHAY_PR_URL}

You're continuing the sashay from the orchestrator role. The branch and draft PR
already exist. Your job is to dispatch a subagent into the worktree to do the
actual implementation.

Do NOT edit the source file yourself. You are the orchestrator.

PROMPT

  # ── Artifact watcher: snapshot files before agent cleanup ──
  # The calling agent may delete plan.yaml and other artifacts after use.
  # This background watcher copies them to a snapshot directory as they appear.
  SNAP="$WORK/.snapshot"
  mkdir -p "$SNAP"
  while true; do
    # Snapshot plan.yaml
    [ -f "$WORK/plan.yaml" ] && [ ! -f "$SNAP/plan.yaml" ] && cp "$WORK/plan.yaml" "$SNAP/plan.yaml" 2>/dev/null || true
    # Snapshot any prompt files
    for f in "$WORK"/prompts/*.md "$WORK"/prompt-*.md; do
      [ -f "$f" ] && [ ! -f "$SNAP/$(basename "$f")" ] && cp "$f" "$SNAP/" 2>/dev/null || true
    done
    # Snapshot .subagents task dirs (all files, not just prompt and start script)
    for d in "$WORK"/.subagents/*/; do
      [ -d "$d" ] || continue
      tid=$(basename "$d")
      [ "$tid" = "plan-"* ] && continue
      [ -d "$SNAP/$tid" ] || mkdir -p "$SNAP/$tid"
      cp "$d"prompt.md "$SNAP/$tid/" 2>/dev/null || true
      cp "$d"start-subagent.sh "$SNAP/$tid/" 2>/dev/null || true
      cp "$d"FINAL_OUTPUT.md "$SNAP/$tid/" 2>/dev/null || true
    done
    sleep 0.2
  done &
  WATCHER_PID=$!

  echo "  Dispatching calling agent (opencode run)..."

  # Detect opencode server for --attach mode (needed when opencode serve is running)
  ATTACH_ARGS=()
  if [ -n "${OPENCODE_SERVER_URL:-}" ]; then
    ATTACH_ARGS=(--attach "$OPENCODE_SERVER_URL" --password "${OPENCODE_SERVER_PASSWORD:-}")
  elif command -v lsof &>/dev/null && lsof -i :4096 -sTCP:LISTEN &>/dev/null; then
    ATTACH_ARGS=(--attach http://localhost:4096)
  fi

  # Run the calling agent. It should write plan.yaml and invoke run-plan.sh.
  # Timeout: 120s. We capture stderr for diagnostics but only care about side effects.
  TIMEOUT_BIN="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)"
  if [ -n "$TIMEOUT_BIN" ]; then
    $TIMEOUT_BIN 120 opencode run \
      --dir "$WORK" \
      --model "ollama-cloud/deepseek-v4-flash:cloud" \
      --agent build \
      "${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}" \
      --dangerously-skip-permissions \
      < "$WORK/calling-agent-prompt.md" \
      >> "$WORK/agent-stdout.log" 2>>"$WORK/agent-stderr.log" || true
  else
    opencode run \
      --dir "$WORK" \
      --model "ollama-cloud/deepseek-v4-flash:cloud" \
      --agent build \
      "${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}" \
      --dangerously-skip-permissions \
      < "$WORK/calling-agent-prompt.md" \
      >> "$WORK/agent-stdout.log" 2>>"$WORK/agent-stderr.log" || true
  fi

  # Stop the artifact watcher
  kill "$WATCHER_PID" 2>/dev/null || true
  wait "$WATCHER_PID" 2>/dev/null || true

  # Final snapshot pass (catch anything the watcher missed)
  [ -f "$WORK/plan.yaml" ] && [ ! -f "$SNAP/plan.yaml" ] && cp "$WORK/plan.yaml" "$SNAP/plan.yaml" 2>/dev/null || true
  for f in "$WORK"/prompts/*.md "$WORK"/prompt-*.md; do
    [ -f "$f" ] && [ ! -f "$SNAP/$(basename "$f")" ] && cp "$f" "$SNAP/" 2>/dev/null || true
  done
  for d in "$WORK"/.subagents/*/; do
    [ -d "$d" ] || continue
    tid=$(basename "$d")
    [ "$tid" = "plan-"* ] && continue
    [ -d "$SNAP/$tid" ] || mkdir -p "$SNAP/$tid"
    cp "$d"prompt.md "$SNAP/$tid/" 2>/dev/null || true
    cp "$d"start-subagent.sh "$SNAP/$tid/" 2>/dev/null || true
    cp "$d"FINAL_OUTPUT.md "$SNAP/$tid/" 2>/dev/null || true
  done

  echo "  Agent session complete. Checking artifacts..."

  # ── Checklist ──
  # Check snapshot first (agent may have deleted originals), then live files.

  # C1: Plan YAML file created (check snapshot first, then live)
  PLAN_YAML=""
  if [ -f "$SNAP/plan.yaml" ]; then
    PLAN_YAML="$SNAP/plan.yaml"
    check C1 0
    echo "  C1 PASS: plan.yaml exists (snapshot)"
  elif [ -f "$WORK/plan.yaml" ]; then
    PLAN_YAML="$WORK/plan.yaml"
    check C1 0
    echo "  C1 PASS: plan.yaml exists (live)"
  else
    check C1 1
    echo "  C1 FAIL: plan.yaml not found"
    echo "  Diagnostics: files in workdir:"
    find "$WORK" -maxdepth 2 -not -path "$WORK/remote/*" -not -path "$WORK/.git/*" -not -path "$WORK/.subagents/*" -not -path "$WORK/shim/*" -not -path "$WORK/.snapshot/*" | head -20
    # Early exit for this run — no plan means nothing else to check
    if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; fi
    return
  fi

  # C2: Plan YAML has kind: pr-work
  local KIND
  KIND=$(python3 -c "
import yaml, sys
with open('$PLAN_YAML') as f:
    plan = yaml.safe_load(f)
tasks = plan.get('tasks', [])
if tasks:
    print(tasks[0].get('kind', ''))
else:
    print('')
" 2>/dev/null || echo "")
  if [ "$KIND" = "pr-work" ]; then
    check C2 0
    echo "  C2 PASS: kind=pr-work"
  else
    check C2 1
    echo "  C2 FAIL: kind='$KIND' (expected pr-work)"
  fi

  # C3: Plan YAML has worktree field
  local WORKTREE
  WORKTREE=$(python3 -c "
import yaml, sys
with open('$PLAN_YAML') as f:
    plan = yaml.safe_load(f)
tasks = plan.get('tasks', [])
if tasks:
    print(tasks[0].get('worktree', ''))
else:
    print('')
" 2>/dev/null || echo "")
  if [ -n "$WORKTREE" ]; then
    check C3 0
    echo "  C3 PASS: worktree='$WORKTREE'"
  else
    check C3 1
    echo "  C3 FAIL: worktree field missing or empty"
  fi

  # C4: Plan YAML has prompt field pointing to existing file (check snapshot)
  local PROMPT_PATH
  PROMPT_PATH=$(python3 -c "
import yaml, sys, os
with open('$PLAN_YAML') as f:
    plan = yaml.safe_load(f)
tasks = plan.get('tasks', [])
if tasks:
    p = tasks[0].get('prompt', '')
    print(p)
else:
    print('')
" 2>/dev/null || echo "")
  local PROMPT_FOUND=""
  if [ -n "$PROMPT_PATH" ]; then
    [ -f "$WORK/$PROMPT_PATH" ] && PROMPT_FOUND="live"
    [ -f "$SNAP/$(basename "$PROMPT_PATH")" ] && PROMPT_FOUND="snapshot"
  fi
  if [ -n "$PROMPT_FOUND" ]; then
    check C4 0
    echo "  C4 PASS: prompt='$PROMPT_PATH' ($PROMPT_FOUND)"
  else
    check C4 1
    echo "  C4 FAIL: prompt='$PROMPT_PATH' (file missing or field empty)"
  fi

  # C5: Plan YAML has model field
  local MODEL
  MODEL=$(python3 -c "
import yaml, sys
with open('$PLAN_YAML') as f:
    plan = yaml.safe_load(f)
tasks = plan.get('tasks', [])
if tasks:
    print(tasks[0].get('model', ''))
else:
    print('')
" 2>/dev/null || echo "")
  if [ -n "$MODEL" ]; then
    check C5 0
    echo "  C5 PASS: model='$MODEL'"
  else
    check C5 1
    echo "  C5 FAIL: model field missing or empty"
  fi

  # C6: .subagents/<task-id> directory exists (dispatch happened) — check snapshot
  local TASK_ID
  TASK_ID=$(python3 -c "
import yaml, sys
with open('$PLAN_YAML') as f:
    plan = yaml.safe_load(f)
tasks = plan.get('tasks', [])
if tasks:
    print(tasks[0].get('id', ''))
else:
    print('')
" 2>/dev/null || echo "")
  local TASK_DIR=""
  [ -d "$WORK/.subagents/$TASK_ID" ] && TASK_DIR="$WORK/.subagents/$TASK_ID"
  [ -z "$TASK_DIR" ] && [ -d "$SNAP/$TASK_ID" ] && TASK_DIR="$SNAP/$TASK_ID"
  if [ -n "$TASK_ID" ] && [ -n "$TASK_DIR" ]; then
    check C6 0
    echo "  C6 PASS: task dir exists for id='$TASK_ID'"
  else
    check C6 1
    echo "  C6 FAIL: task dir not found (id='$TASK_ID')"
  fi

  # C7: start-subagent.sh contains gh pr create (PR creation) — check snapshot
  local START_SCRIPT=""
  if [ -n "$TASK_ID" ] && [ -f "$WORK/.subagents/$TASK_ID/start-subagent.sh" ]; then
    START_SCRIPT="$WORK/.subagents/$TASK_ID/start-subagent.sh"
  elif [ -n "$TASK_ID" ] && [ -f "$SNAP/$TASK_ID/start-subagent.sh" ]; then
    START_SCRIPT="$SNAP/$TASK_ID/start-subagent.sh"
  fi
  if [ -n "$START_SCRIPT" ] && grep -q 'gh pr create' "$START_SCRIPT"; then
    check C7 0
    echo "  C7 PASS: start-subagent.sh has gh pr create"
  elif [ -n "$START_SCRIPT" ]; then
    check C7 1
    echo "  C7 FAIL: start-subagent.sh missing gh pr create"
  else
    check C7 1
    echo "  C7 FAIL: start-subagent.sh not found"
  fi

  # C8: Worktree branch was created
  if [ -n "$WORKTREE" ]; then
    if git -C "$WORK" branch --list "$WORKTREE" | grep -q "$WORKTREE"; then
      check C8 0
      echo "  C8 PASS: worktree branch '$WORKTREE' created"
    else
      check C8 1
      echo "  C8 FAIL: worktree branch not found"
    fi
  else
    check C8 1
    echo "  C8 FAIL: cannot check branch (no worktree field)"
  fi

  # C9: prompt.md copied to task dir — check snapshot
  local PROMPT_MD=""
  if [ -n "$TASK_ID" ] && [ -f "$WORK/.subagents/$TASK_ID/prompt.md" ]; then
    PROMPT_MD="$WORK/.subagents/$TASK_ID/prompt.md"
  elif [ -n "$TASK_ID" ] && [ -f "$SNAP/$TASK_ID/prompt.md" ]; then
    PROMPT_MD="$SNAP/$TASK_ID/prompt.md"
  fi
  if [ -n "$PROMPT_MD" ]; then
    check C9 0
    echo "  C9 PASS: prompt.md in task dir"
  else
    check C9 1
    echo "  C9 FAIL: prompt.md not in task dir"
  fi

  # Clean up dispatched subagents if they exist
  if [ -n "$TASK_ID" ] && [ -d "$WORK/.subagents/$TASK_ID" ]; then
    "$ABANDON" --task-id "$TASK_ID" --root "$WORK" 2>/dev/null || true
  fi

  if [ "$KEEP" -eq 0 ]; then
    rm -rf "$WORK"
  else
    echo "  kept $WORK"
  fi
}

echo "============================================================"
echo " Agent Integration Test: Sashay Invocation Compliance"
echo " N=$N runs"
echo "============================================================"

for ((i=1; i<=N; i++)); do
  run_once "$i"
  RUNS=$((RUNS + 1))
done

# ── Summary ──

echo ""
echo "============================================================"
echo " Compliance Summary: $N runs, $CHECKLIST_TOTAL checks"
echo "============================================================"
echo ""
printf "  %-30s %4s %4s %5s%%\n" "Criterion" "Pass" "Fail" "Rate"
echo "  --------------------------------------------------------"
for c in C1 C2 C3 C4 C5 C6 C7 C8 C9; do
  p_var="${c}_PASS"
  f_var="${c}_FAIL"
  p="${!p_var}"
  f="${!f_var}"
  total=$((p + f))
  if [ "$total" -gt 0 ]; then
    rate=$(( p * 100 / total ))
  else
    rate=0
  fi
  case "$c" in
    C1) label="Plan YAML created" ;;
    C2) label="kind=pr-work" ;;
    C3) label="worktree field" ;;
    C4) label="prompt file exists" ;;
    C5) label="model field" ;;
    C6) label="dispatch happened" ;;
    C7) label="gh pr create in script" ;;
    C8) label="worktree branch created" ;;
    C9) label="prompt.md in task dir" ;;
  esac
  printf "  %-30s %4d %4d %5d%%\n" "$label" "$p" "$f" "$rate"
done
echo ""
overall_rate=0
if [ "$CHECKLIST_TOTAL" -gt 0 ]; then
  overall_rate=$(( PASS_TOTAL * 100 / CHECKLIST_TOTAL ))
fi
echo "  Overall: $PASS_TOTAL/$CHECKLIST_TOTAL passed (${overall_rate}% compliance)"

[ "$FAIL_TOTAL" -eq 0 ] && exit 0 || exit 1