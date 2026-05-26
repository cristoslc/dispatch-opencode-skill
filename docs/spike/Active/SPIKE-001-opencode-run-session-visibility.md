---
title: "opencode run session visibility when OPENCODE_SERVER_PASSWORD is unset"
artifact: SPIKE-001
track: standing
status: Active
author: cristoslc
created: 2026-05-25
last-updated: 2026-05-25
linked-artifacts:
  - ADR-001
depends-on-artifacts: []
parent-epic: ""
evidence-pool: async-subagent-dispatch@5ca7b44
---

# SPIKE-001: opencode run session visibility with unset server password

## Findings

Confirmed by source code (`packages/opencode/src/cli/cmd/run.ts`) and live experiments.

### Without --attach (default)

`opencode run` creates an **in-process server** at `http://opencode.internal` (run.ts:688-691). Sessions are isolated to that process. The server port defaults to random when unset. Sessions are NOT visible on the `opencode serve` daemon running on port 4096. The operator cannot attach.

### With --attach

`opencode run --attach http://localhost:4096` connects to the serve daemon (run.ts:652-655). Sessions ARE created on the serve daemon and ARE visible/attachable. The operator can `opencode attach http://localhost:4096 --session <id>` from another terminal.

The password can be passed via `--password` flag: `--password "$OPENCODE_SERVER_PASSWORD"`. This avoids the env-var leak entirely — the child doesn't need `OPENCODE_SERVER_PASSWORD` in its env because it authenticates via the explicit `--password` argument.

### Key insight for async dispatch

The session-in-session env-var leak (issue #24747) does not apply when using `--attach`. The child is a client of the parent's serve daemon — it sends auth headers via `ServerAuth.headers()`, never spawning its own in-process server. No `unset OPENCODE_SERVER_PASSWORD` needed.

This simplifies the async dispatch contract:
- The serve daemon on port 4096 is the single point of session visibility.
- `start-subagent.sh` uses `--attach http://localhost:4096 --password "$OPENCODE_SERVER_PASSWORD"` — the parent passes the password at invocation time.
- The operator attaches with `opencode attach http://localhost:4096` and sees all background subagent sessions.

## Completion criteria

- [ ] Produce a documented answer to the primary question.
- [ ] Provide a concrete invocation pattern the operator can use to attach to a background subagent.

## Timebox

30 minutes of investigation.

## References

- ADR-001: async `.subagents/` lock-watch as primary dispatch mode
- Trove `async-subagent-dispatch@5ca7b44` — async dispatch patterns
- Issue #24747: OPENCODE_SERVER_PASSWORD env leak
- Issue #16096: run --attach missing auth headers (fixed PR #16097)
- `packages/opencode/src/cli/cmd/run.ts` — local vs attach auth paths

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-05-25 | — | User-requested, time-boxed investigation. |
