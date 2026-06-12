#!/usr/bin/env bash
# test_agent_sashay_invocation.sh — agent integration test for dispatch-opencode
# invocability in a sashay context.
#
# Spawns a real opencode session as the "calling agent" continuing an existing
# sashay: branch, worktree, and remote PR already exist. Checks whether the
# agent correctly discovers and invokes dispatch-opencode and the subagent
# produces results in the worktree.
#
# Checklist:
#   C1: Dispatch happened (.subagents/<task-id>/start-subagent.sh exists)
#   C2: Subagent CWD points to the sashay worktree
#   C3: prompt.md in task dir
#   C4: Fix commit in worktree branch
#   C5: Source file fixed in worktree (add returns a+b)
#   C6: Fix pushed to remote
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
ABANDON="$SKILL_DIR/scripts/subagent-abandon.sh"

SASHAY_BRANCH="fix-add-sashay"
SASHAY_PR_URL="https://github.com/test/repo/pull/42"

N=1; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) shift; N="${1:-1}"; shift ;;
    --keep) KEEP=1; shift ;;
    *) shift ;;
  esac
done

PASS=0; FAIL=0; CHECKS=0; RUNS=0
C1P=0; C1F=0; C2P=0; C2F=0; C3P=0; C3F=0
C4P=0; C4F=0; C5P=0; C5F=0; C6P=0; C6F=0

check() { local l="$1" r="$2"; CHECKS=$((CHECKS+1)); if [ "$r" = "0" ]; then PASS=$((PASS+1)); eval "${l}P=$((${l}P+1))"; else FAIL=$((FAIL+1)); eval "${l}F=$((${l}F+1))"; fi; }

run_once() {
  local run_num="$1" WORK
  WORK=$(mktemp -d "/tmp/oc-sashay-agent.${run_num}.XXXXXX")
  echo ""
  echo "=== Run $run_num: $WORK ==="

  # Git repo with remote
  mkdir -p "$WORK/remote" "$WORK/shim" "$WORK/.opencode/skills"
  cp -r "$SKILL_DIR" "$WORK/.opencode/skills/dispatch-opencode"
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
  printf '.opencode/\n' >> .gitignore
  git add -A && git commit -q -m "fixture: initial commit"
  git push -q origin main

  # Sashay setup: existing branch + worktree + PR
  git checkout -q -b "$SASHAY_BRANCH"
  git push -q origin "$SASHAY_BRANCH"
  git checkout -q main
  git worktree add "$WORK/.worktrees/$SASHAY_BRANCH" "$SASHAY_BRANCH"

  # gh shim
  cat > "$WORK/shim/gh" <<'SHIM'
#!/usr/bin/env bash
echo "https://github.com/test/repo/pull/42"
SHIM
  chmod +x "$WORK/shim/gh"

  # Prompt: task-level, references sashay context
  cat > "$WORK/calling-agent-prompt.md" <<PROMPT
Fix the bug in src/foo.py: the add() function returns a - b instead of a + b.

A sashay has been started for this fix:
- Branch: ${SASHAY_BRANCH} (pushed to remote)
- Draft PR: ${SASHAY_PR_URL}
- Worktree: .worktrees/${SASHAY_BRANCH}

Continue the sashay. The branch, worktree, and draft PR already exist.
Dispatch a subagent into the worktree to fix the bug. The dispatch-opencode
skill is available in .opencode/skills/dispatch-opencode/ — read its SKILL.md
and use it.

Do NOT edit any source files yourself.
PROMPT

  # Artifact watcher
  SNAP="$WORK/.snapshot"; mkdir -p "$SNAP"
  while true; do
    for d in "$WORK"/.subagents/*/; do
      [ -d "$d" ] || continue; tid=$(basename "$d")
      [ "$tid" = "plan-"* ] && continue
      [ -d "$SNAP/$tid" ] || mkdir -p "$SNAP/$tid"
      cp "$d"start-subagent.sh "$SNAP/$tid/" 2>/dev/null || true
      cp "$d"prompt.md "$SNAP/$tid/" 2>/dev/null || true
      cp "$d"FINAL_OUTPUT.md "$SNAP/$tid/" 2>/dev/null || true
    done
    sleep 0.2
  done &
  WATCHER_PID=$!

  echo "  Dispatching calling agent (opencode run)..."

  ATTACH_ARGS=()
  if [ -n "${OPENCODE_SERVER_URL:-}" ]; then
    ATTACH_ARGS=(--attach "$OPENCODE_SERVER_URL" --password "${OPENCODE_SERVER_PASSWORD:-}")
  elif command -v lsof &>/dev/null && lsof -i :4096 -sTCP:LISTEN &>/dev/null; then
    ATTACH_ARGS=(--attach http://localhost:4096)
  fi

  TIMEOUT_BIN="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)"
  if [ -n "$TIMEOUT_BIN" ]; then
    $TIMEOUT_BIN 180 opencode run \
      --dir "$WORK" --model "ollama-cloud/deepseek-v4-flash:cloud" --agent build \
      "${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}" --dangerously-skip-permissions \
      < "$WORK/calling-agent-prompt.md" \
      >> "$WORK/agent-stdout.log" 2>>"$WORK/agent-stderr.log" || true
  else
    opencode run \
      --dir "$WORK" --model "ollama-cloud/deepseek-v4-flash:cloud" --agent build \
      "${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}" --dangerously-skip-permissions \
      < "$WORK/calling-agent-prompt.md" \
      >> "$WORK/agent-stdout.log" 2>>"$WORK/agent-stderr.log" || true
  fi

  kill "$WATCHER_PID" 2>/dev/null || true; wait "$WATCHER_PID" 2>/dev/null || true

  # Final snapshot pass
  for d in "$WORK"/.subagents/*/; do
    [ -d "$d" ] || continue; tid=$(basename "$d")
    [ "$tid" = "plan-"* ] && continue
    [ -d "$SNAP/$tid" ] || mkdir -p "$SNAP/$tid"
    cp "$d"start-subagent.sh "$SNAP/$tid/" 2>/dev/null || true
    cp "$d"prompt.md "$SNAP/$tid/" 2>/dev/null || true
    cp "$d"FINAL_OUTPUT.md "$SNAP/$tid/" 2>/dev/null || true
  done

  echo "  Agent session complete. Checking artifacts..."

  # C1: Dispatch happened (start-subagent.sh exists in snapshot or live)
  local START_SCRIPT="" TASK_ID=""
  for d in "$SNAP"/*/; do
    [ -d "$d" ] || continue; tid=$(basename "$d")
    [ "$tid" = "plan-"* ] && continue
    if [ -f "$d/start-subagent.sh" ]; then
      START_SCRIPT="$d/start-subagent.sh"; TASK_ID="$tid"; break
    fi
  done
  if [ -z "$START_SCRIPT" ]; then
    for d in "$WORK"/.subagents/*/; do
      [ -d "$d" ] || continue; tid=$(basename "$d")
      [ "$tid" = "plan-"* ] && continue
      if [ -f "$d/start-subagent.sh" ]; then
        START_SCRIPT="$d/start-subagent.sh"; TASK_ID="$tid"; break
      fi
    done
  fi
  if [ -n "$START_SCRIPT" ]; then
    check C1 0; echo "  C1 PASS: dispatch happened (task $TASK_ID)"
  else
    check C1 1; echo "  C1 FAIL: no start-subagent.sh found (no dispatch)"
    echo "  Diagnostics:"; find "$SNAP" -type f 2>/dev/null | head -10
    [ "$KEEP" -eq 0 ] && rm -rf "$WORK"; return
  fi

  # C2: Subagent CWD points to the sashay worktree
  if grep -q "CWD=.*$SASHAY_BRANCH" "$START_SCRIPT" 2>/dev/null; then
    check C2 0; echo "  C2 PASS: subagent CWD points to worktree"
  else
    check C2 1; echo "  C2 FAIL: subagent CWD not in worktree"
  fi

  # C3: prompt.md in task dir
  local PM=""
  [ -f "$SNAP/$TASK_ID/prompt.md" ] && PM="$SNAP/$TASK_ID/prompt.md"
  [ -z "$PM" ] && [ -f "$WORK/.subagents/$TASK_ID/prompt.md" ] && PM="$WORK/.subagents/$TASK_ID/prompt.md"
  if [ -n "$PM" ]; then
    check C3 0; echo "  C3 PASS: prompt.md in task dir"
  else
    check C3 1; echo "  C3 FAIL: prompt.md not found"
  fi

  # C4: Fix commit in worktree branch
  if git -C "$WORK/.worktrees/$SASHAY_BRANCH" log --oneline 2>/dev/null | head -3 | grep -qi "fix\|add\|+"; then
    check C4 0; echo "  C4 PASS: fix commit in worktree branch"
  else
    check C4 1; echo "  C4 FAIL: no fix commit in worktree branch"
  fi

  # C5: Source file fixed in worktree
  if [ -f "$WORK/.worktrees/$SASHAY_BRANCH/src/foo.py" ] && \
     grep -q 'return a + b' "$WORK/.worktrees/$SASHAY_BRANCH/src/foo.py" 2>/dev/null; then
    check C5 0; echo "  C5 PASS: src/foo.py fixed in worktree"
  else
    check C5 1; echo "  C5 FAIL: src/foo.py not fixed in worktree"
  fi

  # C6: Fix pushed to remote
  if git -C "$WORK" fetch -q origin "$SASHAY_BRANCH" 2>/dev/null && \
     git -C "$WORK" log "origin/$SASHAY_BRANCH" --oneline 2>/dev/null | head -3 | grep -qi "fix\|add\|+"; then
    check C6 0; echo "  C6 PASS: fix pushed to remote"
  else
    check C6 1; echo "  C6 FAIL: fix not pushed to remote"
  fi

  # Cleanup
  if [ -n "$TASK_ID" ] && [ -d "$WORK/.subagents/$TASK_ID" ]; then
    "$ABANDON" --task-id "$TASK_ID" --root "$WORK" 2>/dev/null || true
  fi
  [ "$KEEP" -eq 0 ] && rm -rf "$WORK" || echo "  kept $WORK"
}

echo "============================================================"
echo " Agent Integration Test: Sashay Invocation Compliance"
echo " N=$N runs"
echo "============================================================"
for ((i=1; i<=N; i++)); do run_once "$i"; RUNS=$((RUNS+1)); done

echo ""
echo "============================================================"
echo " Compliance Summary: $N runs, $CHECKS checks"
echo "============================================================"
echo ""
printf "  %-35s %4s %4s %5s%%\n" "Criterion" "Pass" "Fail" "Rate"
echo "  --------------------------------------------------------"
for c in C1 C2 C3 C4 C5 C6; do
  p_var="${c}P"; f_var="${c}F"
  p="${!p_var}"; f="${!f_var}"
  total=$((p+f)); rate=0
  [ "$total" -gt 0 ] && rate=$(( p * 100 / total ))
  case "$c" in
    C1) label="Dispatch happened" ;; C2) label="CWD points to worktree" ;;
    C3) label="prompt.md in task dir" ;; C4) label="Fix commit in branch" ;;
    C5) label="Source file fixed" ;; C6) label="Fix pushed to remote" ;;
  esac
  printf "  %-35s %4d %4d %5d%%\n" "$label" "$p" "$f" "$rate"
done
echo ""
rate=0; [ "$CHECKS" -gt 0 ] && rate=$(( PASS * 100 / CHECKS ))
echo "  Overall: $PASS/$CHECKS passed (${rate}% compliance)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1