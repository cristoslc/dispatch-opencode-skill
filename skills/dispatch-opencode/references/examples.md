# Examples

Concrete invocations of the CLI dispatch template. The skill writes `start-subagent.sh` to `.subagents/<task-id>/` and spawns it in the background.

## Basic single-file fix

The async lock-watch pattern. The parent writes the dispatch artifact and polls `.lock` for completion.

```sh
TASK_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(echo 'fix bug in foo.py' | shasum -a 256 | cut -c1-8)"
TASK_DIR=".subagents/$TASK_ID"
mkdir -p "$TASK_DIR"

# Write the prompt
cat > "$TASK_DIR/prompt.md" <<'MD'
Fix the arithmetic bug in src/foo.py. The `add` function uses subtraction
instead of addition. Change `a - b` to `a + b`.
MD

# Write and spawn the start script
cat > "$TASK_DIR/start-subagent.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "$$" > "$TASK_DIR/.lock"
export OPENCODE_DISABLE_AUTOCOMPACT=true
export OPENCODE_DISABLE_AUTOUPDATE=true
opencode run \
  --attach "$OPENCODE_SERVER_URL" --password "$OPENCODE_SERVER_PASSWORD" \
  --model ollama-cloud/glm-5.1 --agent build --format json \
  --dangerously-skip-permissions --file src/foo.py \
  < "$TASK_DIR/prompt.md" \
  2> "$TASK_DIR/stderr.log" \
  | tee "$TASK_DIR/events.jsonl" > "$TASK_DIR/stdout.log"
EXIT=$?
rm -f "$TASK_DIR/.lock"
echo "[dispatch-opencode] exit=$EXIT"
exit "$EXIT"
SH

chmod +x "$TASK_DIR/start-subagent.sh"
bash "$TASK_DIR/start-subagent.sh" &
PID=$!
echo "spawned subagent pid=$PID task_dir=$TASK_DIR"

# Poll for completion
while [ -f "$TASK_DIR/.lock" ]; do
  AGE=$(( $(date +%s) - $(stat -f %m "$TASK_DIR/.lock") ))
  if [ "$AGE" -gt 600 ]; then
    echo "stall detected — killing pid=$PID"
    kill "$PID" 2>/dev/null || true
    break
  fi
  sleep 2
done

# Read result
cat "$TASK_DIR/FINAL_OUTPUT.md" 2>/dev/null || echo "no FINAL_OUTPUT.md"
```

## Parallel fan-out (N subagents)

Spawn N subagents, each with its own `.lock`. Poll all `.lock` files in a loop:

```sh
for task in "${TASK_DIRS[@]}"; do
  bash "$task/start-subagent.sh" &
done

# Poll all until done or timeout
while true; do
  remaining=()
  for task in "${TASK_DIRS[@]}"; do
    [ -f "$task/.lock" ] && remaining+=("$task")
  done
  [ "${#remaining[@]}" -eq 0 ] && break
  sleep 2
done
```

## Attaching to a subagent

Since the subagent uses `--attach` to the serve daemon, the operator can attach from another terminal:

```sh
opencode attach http://localhost:4096 --session <session-id>
```

The session ID is in the first line of `events.jsonl`:

```sh
head -1 .subagents/<task-id>/events.jsonl | jq -r '.sessionID'
```
