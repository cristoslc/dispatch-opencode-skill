# Examples

Concrete invocations of the dispatch-opencode skill.

## Single task via run-plan.sh

The agent writes a 1-task plan, dispatches it, and polls the lockfile.

```sh
# 1. Write the plan
cat > plan.yaml <<'YAML'
tasks:
  - id: fix-foo
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompt-fix-foo.md
    target: src/foo.py
YAML

# 2. Write the prompt
cat > prompt-fix-foo.md <<'MD'
Fix the arithmetic bug in src/foo.py. The `add` function uses subtraction
instead of addition. Change `a - b` to `a + b`.
MD

# 3. Dispatch
result=$(bash skills/dispatch-opencode/scripts/run-plan.sh --plan plan.yaml)
lockfile=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['lockfile'])")
task_dir=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['task_dir'])")

# 4. Poll for completion (recommended: use poll-subagent.sh)
#    Exit 0 = completed, 2 = stuck, 3 = timeout
bash skills/dispatch-opencode/scripts/poll-subagent.sh \
  --task-id fix-foo --root "$(git rev-parse --show-toplevel)" \
  --max-polls 12 --stale-threshold 60
# Or, for complex tasks:
#   --max-polls 16

# 5. Read result
cat "$task_dir/FINAL_OUTPUT.md"

# 6. Merge work and clean up
# (agent's choice: merge, PR, squash, etc.)
bash skills/dispatch-opencode/scripts/subagent-cleanup.sh --task-id fix-foo --root "$(git rev-parse --show-toplevel)"
```

## Parallelize N tasks via run-plan.sh

```sh
cat > plan.yaml <<'YAML'
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    worktree: fix-auth-branch
  - id: fix-logging
    kind: single-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/fix-logging.md
    target: src/logging.py
    worktree: fix-logging-branch
YAML

result=$(bash skills/dispatch-opencode/scripts/run-plan.sh --plan plan.yaml)

# Poll each task (recommended: use poll-subagent.sh per task)
# Exit codes: 0 = completed, 2 = stuck, 3 = timeout
tasks=$(echo "$result" | python3 -c "
import json, sys
for t in json.load(sys.stdin)['tasks']:
    if t['status'] == 'dispatched':
        print(t['id'])
")

for tid in $tasks; do
  bash skills/dispatch-opencode/scripts/poll-subagent.sh \
    --task-id "$tid" --root "$(git rev-parse --show-toplevel)" \
    --max-polls 12 --stale-threshold 60 &
done
wait

# Read results, merge, clean up each task
# ...
bash skills/dispatch-opencode/scripts/subagent-cleanup.sh --task-id fix-auth --root "$(git rev-parse --show-toplevel)"
bash skills/dispatch-opencode/scripts/subagent-cleanup.sh --task-id fix-logging --root "$(git rev-parse --show-toplevel)"
```

## Abandon a failed task

```sh
bash skills/dispatch-opencode/scripts/subagent-abandon.sh --task-id fix-auth --root "$(git rev-parse --show-toplevel)"
# Kills PID, force-removes worktree, deletes branch, removes task dir.
```

## Stale resource recovery

```sh
# Report only
bash skills/dispatch-opencode/scripts/cleanup-stale.sh /path/to/repo

# Report and clean up
bash skills/dispatch-opencode/scripts/cleanup-stale.sh --abandon /path/to/repo
```

## Attaching to a subagent

Since the subagent uses `--attach` to the serve daemon, the operator can
attach from another terminal:

```sh
opencode attach http://localhost:4096 --session <session-id>
```

The session ID is in the first line of `events.jsonl`:

```sh
head -1 .subagents/<task-id>/events.jsonl | jq -r '.sessionID'
```

## PR-work flow

Create a draft PR and dispatch an agent to work in the worktree:

```sh
# 1. Write the plan
cat > plan.yaml <<'YAML'
tasks:
  - id: implement-feature
    kind: pr-work
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/feature-plan.md
    worktree: feat-123-branch
    pr_title: "Feat: implement feature X"
YAML

# 2. Write the prompt (becomes the PR body)
echo '# Feature X

Implement feature X according to the spec at docs/specs/feature-x.md.

## Working guidelines
- Commit and push your progress
- Add PR comments for each significant checkpoint
- All tests must pass before completion' > prompts/feature-plan.md

# 3. Dispatch
result=$(bash skills/dispatch-opencode/scripts/run-plan.sh --plan plan.yaml)
task_dir=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['task_dir'])")

# 4. Poll for completion
bash skills/dispatch-opencode/scripts/poll-subagent.sh \
  --task-id implement-feature --root "$(git rev-parse --show-toplevel)" \
  --max-polls 24 --stale-threshold 120

# 5. Read result (includes PR URL)
cat "$task_dir/FINAL_OUTPUT.md"

# 6. Clean up worktree only (branch + PR survive on remote)
bash skills/dispatch-opencode/scripts/subagent-cleanup.sh \
  --task-id implement-feature --root "$(git rev-parse --show-toplevel)"

# 7. Operator reviews the PR with full chronicle in comments/commits
# Optional: mark PR ready for review
gh pr ready implement-feature
```