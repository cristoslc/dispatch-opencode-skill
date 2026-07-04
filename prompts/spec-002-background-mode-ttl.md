# SPEC-002: Background Mode and TTL in Plan Schema

Update the plan schema and watcher scripts to support `mode: foreground | background` and `ttl_sec` fields.

## Changes needed

### 1. `run-plan.sh` — Parse `mode` and `ttl_sec` from plan YAML

The plan YAML parser already extracts fields from each task. Add `mode` and `ttl_sec` to the parsed fields. These are informational for `run-plan.sh` — it doesn't need to act on them, but they should be accepted without error.

In the Python parsing block (around line 55-101), add:
```python
mode = t.get('mode', 'foreground')
ttl_sec = t.get('ttl_sec', 1800)
```

These don't need to be in the TSV output — they're consumed by the watcher, not by `run-plan.sh`.

### 2. `watcher-process.sh` — Already handles `ttl_sec`

The watcher-process.sh already parses `ttl_sec` from the plan YAML (lines 46-57) and enforces it in the poll loop (lines 156-164). This is already correct.

### 3. `watcher-process.sh` — Filter by `mode`

Add a check: when parsing the plan YAML, skip tasks where `mode` is `foreground` (they should go through `run-plan.sh` directly, not through the watcher). Only process tasks with `mode: background`.

In the TTL parsing Python block (lines 46-57), also extract `mode`:
```python
for t in tasks:
    tid = t.get('id', '')
    mode = t.get('mode', 'foreground')
    ttl = t.get('ttl_sec', 1800)
    result[tid] = {'ttl': ttl, 'mode': mode}
```

Then in the poll loop, skip tasks where `mode == 'foreground'`:
```python
# After parsing TASK_JSON, check mode
TASK_MODE=$(echo "$TASK_TTLS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$TASK_ID', {}).get('mode', 'foreground'))" 2>/dev/null || echo "foreground")
if [ "$TASK_MODE" = "foreground" ]; then
  log "task=$TASK_ID mode=foreground — skipping (handled by run-plan.sh directly)"
  continue
fi
```

### 4. Update plan schema documentation

The plan schema now supports:
```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    mode: background       # "foreground" (default) or "background"
    ttl_sec: 3600          # optional, only meaningful in background mode (default 1800)
```

## Files to modify

- `skills/dispatch-opencode/scripts/run-plan.sh` — accept `mode` and `ttl_sec` in YAML parser (no behavioral change)
- `skills/dispatch-opencode/scripts/watcher-process.sh` — filter by `mode`, skip foreground tasks

## Acceptance criteria

1. Plan YAML with `mode: background` is valid and parseable
2. Plan YAML with `mode: foreground` (or omitted) is handled by existing flow unchanged
3. Plan YAML with `ttl_sec: 60` causes watcher to kill subagent after 60s
4. Plan YAML without `ttl_sec` defaults to 1800s
5. Watcher skips `mode: foreground` tasks and processes only `mode: background` tasks
6. `run-plan.sh` accepts `mode` and `ttl_sec` fields without error
