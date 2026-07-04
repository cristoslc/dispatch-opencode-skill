---
title: "Watcher Daemon for Background Dispatch"
artifact: EPIC-001
track: container
status: Active
author: swain
created: 2026-07-03
last-updated: 2026-07-03
parent-vision: ""
parent-initiative: ""
priority-weight: high
success-criteria:
  - Watcher daemon script (start/stop/status) exists and is functional
  - Plan schema supports `mode: foreground | background` and `ttl_sec` fields
  - Background dispatch flow works end-to-end: agent writes plan to watch dir, watcher picks it up, dispatches, polls, cleans up
  - TTL enforcement kills background agents that exceed their wall-clock deadline
  - SKILL.md documents the new background dispatch workflow
depends-on-artifacts: []
addresses: []
evidence-pool: ""
---

# Watcher Daemon for Background Dispatch

## Goal / Objective

Split the orchestrator's Planner and Watcher roles so agents can fire-and-forget background tasks. Add a persistent watcher daemon that monitors a directory for plan YAMLs, dispatches them, polls for completion, enforces TTL, and cleans up.

## Desired Outcomes

Agents (and operators) can dispatch long-running tasks without blocking their own session. The watcher daemon handles the entire lifecycle: pickup, dispatch, poll, TTL enforcement, cleanup, result reporting. The agent just writes a plan with `mode: background` and moves on.

## Progress

<!-- Auto-populated from session digests. See progress.md for full log. -->

## Scope Boundaries

**In scope:**
- Watcher daemon script (`watcher.sh`) with start/stop/status
- Plan processing script (`watcher-process.sh`) called by the daemon
- `mode: background` and `ttl_sec` fields in plan schema
- Background dispatch flow: agent writes plan to `.subagents/watch/`, watcher picks it up
- TTL enforcement: watcher kills subagents that exceed their deadline
- Result reporting: watcher writes summaries to `.subagents/watch/results/`
- SKILL.md updates documenting the new workflow

**Out of scope:**
- Changes to existing foreground dispatch flow (run-plan.sh, dispatch.sh, templates)
- Changes to existing scripts (poll-subagent.sh, subagent-cleanup.sh, subagent-abandon.sh)
- Multiple watch directories (v1 supports one per project root)
- Retry logic for failed background tasks
- Web UI or dashboard for background task status

## Child Specs

- SPEC-001: Watcher daemon script (start/stop/status, watch loop)
- SPEC-002: Background mode in plan schema + TTL field
- SPEC-003: SKILL.md updates for background dispatch workflow

## Key Dependencies

- Existing dispatch.sh, run-plan.sh, poll-subagent.sh, subagent-cleanup.sh, subagent-abandon.sh (unchanged, used by watcher internally)
- opencode CLI (for `opencode run` — unchanged)
- Python 3 (for template rendering — already a dependency)

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-07-03 | -- | Initial creation |
