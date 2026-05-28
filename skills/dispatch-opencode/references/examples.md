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

# 4. Poll the lockfile (~15s interval)
while [ -f "$lockfile" ]; do sleep 15; done

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

# Poll all lockfiles
lockfiles=$(echo "$result" | python3 -c "
import json, sys
for t in json.load(sys.stdin)['tasks']:
    if t['status'] == 'dispatched':
        print(t['lockfile'])
")

while true; do
  remaining=0
  while read -r lf; do
    [ -f "$lf" ] && remaining=$((remaining + 1))
  done <<< "$lockfiles"
  [ "$remaining" -eq 0 ] && break
  sleep 15
done

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