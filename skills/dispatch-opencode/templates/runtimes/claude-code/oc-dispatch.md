---
description: Dispatch a subagent task through opencode (single-file-fix or headless-spike) using the async .subagents/ lock-watch protocol. Bypasses Claude Code's built-in subagent runtime.
argument-hint: <kind> <target-or-report> <prompt-file> [extra flags]
---

Run the bash tool with the following. Set `$REPO_ROOT` to the absolute path of the project root.

```sh
REPO_ROOT="$(git rev-parse --show-toplevel)"
TASK_DIR="$REPO_ROOT/.subagents/$(date -u +%Y%m%dT%H%M%SZ)-$(echo "$*" | shasum -a 256 | cut -c1-8)"
mkdir -p "$TASK_DIR"

KIND="$1"; shift
case "$KIND" in
  single-file-fix)
    TARGET="$1"; shift
    PROMPT_FILE="$1"; shift
    cp "$PROMPT_FILE" "$TASK_DIR/prompt.md"
    # Render the CLI template to start-subagent.sh
    cat > "$TASK_DIR/start-subagent.sh" <<SH
#!/usr/bin/env bash
set -uo pipefail
TASK_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
echo "\$\$" > "\$TASK_DIR/.lock"
export OPENCODE_DISABLE_AUTOCOMPACT=true
export OPENCODE_DISABLE_AUTOUPDATE=true
if [ -n "\${OPENCODE_SERVER_URL:-}" ]; then
  ATTACH_ARGS=(--attach "\$OPENCODE_SERVER_URL" --password "\$OPENCODE_SERVER_PASSWORD")
else
  ATTACH_ARGS=(--dir "$REPO_ROOT")
fi
opencode run \
  "\${ATTACH_ARGS[@]}" \
  --model "$MODEL" --agent build --format json \
  --dangerously-skip-permissions --file "$TARGET" \
  < "\$TASK_DIR/prompt.md" \
  2> "\$TASK_DIR/stderr.log" \
  | tee "\$TASK_DIR/events.jsonl" > "\$TASK_DIR/stdout.log"
EXIT=\$?
rm -f "\$TASK_DIR/.lock"
echo "[dispatch-opencode] exit=\$EXIT"
exit "\$EXIT"
SH
    chmod +x "$TASK_DIR/start-subagent.sh"
    bash "$TASK_DIR/start-subagent.sh" &
    echo "subagent spawned: $TASK_DIR"
    echo "poll with: while [ -f $TASK_DIR/.lock ]; do sleep 2; done"
    ;;
  headless-spike)
    REPORT_PATH="$1"; shift
    PROMPT_FILE="$1"; shift
    # Same structure as single-file-fix, but with --agent explore and --port for local server
    cp "$PROMPT_FILE" "$TASK_DIR/prompt.md"
    cat > "$TASK_DIR/start-subagent.sh" <<SH
#!/usr/bin/env bash
set -uo pipefail
TASK_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
echo "\$\$" > "\$TASK_DIR/.lock"
export OPENCODE_DISABLE_AUTOCOMPACT=true
export OPENCODE_DISABLE_AUTOUPDATE=true
opencode run \
  --dir "$REPO_ROOT" \
  --model "$MODEL" --agent explore --format json \
  --dangerously-skip-permissions --file "$REPORT_PATH" \
  < "\$TASK_DIR/prompt.md" \
  2> "\$TASK_DIR/stderr.log" \
  | tee "\$TASK_DIR/events.jsonl" > "\$TASK_DIR/stdout.log"
EXIT=\$?
rm -f "\$TASK_DIR/.lock"
echo "[dispatch-opencode] exit=\$EXIT"
exit "\$EXIT"
SH
    chmod +x "$TASK_DIR/start-subagent.sh"
    bash "$TASK_DIR/start-subagent.sh" &
    echo "subagent spawned: $TASK_DIR"
    ;;
  *)
    echo "unknown kind: $KIND (expected single-file-fix | headless-spike)" >&2
    rm -rf "$TASK_DIR"
    exit 2
    ;;
esac
```

After dispatch, surface the rendered `.subagents/<task-id>/` directory. The operator can attach from another terminal with `opencode attach http://localhost:4096 --session <id>` — extract the session ID from `head -1 .subagents/<task-id>/events.jsonl`.

To install: copy this file to `.claude/commands/oc-dispatch.md` in the consumer project. The operator then invokes:

- `/oc-dispatch single-file-fix src/foo.py prompt.md`
- `/oc-dispatch headless-spike reports/spike.md prompt.md`
