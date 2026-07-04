---
title: "Background Mode and TTL in Plan Schema"
artifact: SPEC-002
track: implementable
status: Proposed
author: swain
created: 2026-07-03
last-updated: 2026-07-03
priority-weight: high
type: ""
parent-epic: EPIC-001
parent-initiative: ""
linked-artifacts: []
depends-on-artifacts:
  - SPEC-001
addresses: []
evidence-pool: ""
source-issue: ""
swain-do: required
---

# Background Mode and TTL in Plan Schema

## Problem Statement

The plan schema currently has no concept of foreground vs. background dispatch. The agent needs a way to signal "fire-and-forget this task" and optionally set a wall-clock deadline. The watcher daemon (SPEC-001) needs to read these fields to know how to handle each task.

## Desired Outcomes

The plan schema supports `mode: foreground | background` and `ttl_sec` fields. The watcher daemon reads these fields and enforces TTL for background tasks. Foreground tasks are handled by the existing `run-plan.sh` flow unchanged.

## External Behavior

**Plan schema additions:**

```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    mode: background       # "foreground" (default) or "background"
    ttl_sec: 3600          # optional, only meaningful in background mode
```

- `mode` — optional, defaults to `foreground`. When `foreground`, the agent calls `run-plan.sh` directly (current behavior). When `background`, the agent writes the plan to `.subagents/watch/` and the watcher picks it up.
- `ttl_sec` — optional, only meaningful when `mode: background`. Wall-clock deadline in seconds. Default: 1800 (30 minutes). The watcher kills the subagent and abandons the task if `now - dispatch_time > ttl_sec`.

**Agent workflow for background dispatch:**

1. Agent writes plan YAML with `mode: background` (and optionally `ttl_sec`)
2. Agent writes the plan to `.subagents/watch/<plan-name>.yaml`
3. Agent continues working — does NOT call `run-plan.sh` or `poll-subagent.sh`
4. Agent can later check `.subagents/watch/results/<task-id>.md` for results

**Watcher behavior:**

- Reads `mode` field from each task in the plan
- Skips tasks with `mode: foreground` (they should go through `run-plan.sh` directly)
- For `mode: background` tasks, dispatches via `run-plan.sh` and manages the lifecycle
- Enforces TTL: if `now - dispatch_time > ttl_sec`, kills the subagent and calls `subagent-abandon.sh`
- Writes result summaries to `results/<task-id>.md`

## Acceptance Criteria

1. Plan YAML with `mode: background` is valid and parseable by the watcher.
2. Plan YAML with `mode: foreground` (or omitted) is handled by the existing `run-plan.sh` flow unchanged.
3. Plan YAML with `ttl_sec: 60` causes the watcher to kill the subagent after 60 seconds.
4. Plan YAML without `ttl_sec` defaults to 1800 seconds (30 minutes).
5. The watcher skips `mode: foreground` tasks in a plan and processes only `mode: background` tasks.
6. The agent can write a plan to `.subagents/watch/` and the watcher picks it up without the agent calling `run-plan.sh`.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|
| | | |

## Scope & Constraints

- No changes to the existing `run-plan.sh` script — it stays as-is for foreground dispatch
- The `mode` field is per-task, not per-plan (a plan could theoretically mix modes, though the watcher only processes background tasks)
- TTL is a wall-clock deadline, not a CPU-time limit
- TTL enforcement is the watcher's responsibility, not the subagent's

## Implementation Approach

1. Update `run-plan.sh`'s plan parsing to accept `mode` and `ttl_sec` fields (they're already parsed via YAML, just need to be passed through)
2. Update `watcher-process.sh` (SPEC-001) to read `mode` and `ttl_sec` from each task
3. Add TTL check to the watcher's poll loop
4. Update the plan schema documentation in SKILL.md

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-07-03 | -- | Initial creation |
