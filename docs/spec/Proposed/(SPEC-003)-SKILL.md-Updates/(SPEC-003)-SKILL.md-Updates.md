---
title: "SKILL.md Updates for Background Dispatch Workflow"
artifact: SPEC-003
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
  - SPEC-002
addresses: []
evidence-pool: ""
source-issue: ""
swain-do: required
---

# SKILL.md Updates for Background Dispatch Workflow

## Problem Statement

The SKILL.md documents foreground dispatch only. It needs new sections for the background dispatch workflow, watcher daemon usage, and the updated plan schema with `mode` and `ttl_sec` fields.

## Desired Outcomes

The SKILL.md is the single source of truth for how agents use dispatch-opencode. It documents both foreground and background dispatch, the watcher daemon, and the full plan schema.

## External Behavior

**New sections in SKILL.md:**

1. **"Background dispatch" workflow** — agent writes plan to `.subagents/watch/`, continues working, checks results later
2. **"Watcher daemon" section** — how to start/stop/check status
3. **Updated plan schema** — `mode` and `ttl_sec` fields documented
4. **Updated script inventory** — `watcher.sh` and `watcher-process.sh` added
5. **Updated directory structure** — `.subagents/watch/` layout documented

**Updated plan schema table:**

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Task identifier |
| `kind` | yes | Dispatch kind |
| `model` | yes | Provider/model string |
| `prompt` | yes | Path to prompt file |
| `target` | for single-file-fix | Target file path |
| `worktree` | no | Branch name for worktree |
| `agent` | no | Agent type (defaults per kind) |
| `mode` | no | `foreground` (default) or `background` |
| `ttl_sec` | no | Wall-clock deadline in seconds (background only, default 1800) |

## Acceptance Criteria

1. SKILL.md has a "Background dispatch" workflow section.
2. SKILL.md has a "Watcher daemon" section with start/stop/status commands.
3. SKILL.md plan schema table includes `mode` and `ttl_sec` fields.
4. SKILL.md script inventory includes `watcher.sh` and `watcher-process.sh`.
5. SKILL.md directory structure includes `.subagents/watch/` layout.
6. The "When to use" section mentions background dispatch for long-running tasks.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|
| | | |

## Scope & Constraints

- Only SKILL.md changes — no changes to reference docs, troubleshooting, or examples
- The existing foreground dispatch documentation is preserved unchanged
- New sections are additive, not replacements

## Implementation Approach

1. Edit `skills/dispatch-opencode/SKILL.md`
2. Add "Background dispatch" workflow after existing "Single task" workflow
3. Add "Watcher daemon" section after "Script inventory"
4. Update plan schema table with `mode` and `ttl_sec`
5. Update script inventory with new scripts
6. Update directory structure with watch/ layout

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-07-03 | -- | Initial creation |
