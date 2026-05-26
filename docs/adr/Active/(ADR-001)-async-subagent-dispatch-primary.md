---
title: "Async .subagents/ lock-watch as primary dispatch mode; drop ACP"
artifact: ADR-001
track: standing
status: Active
author: cristoslc
created: 2026-05-25
last-updated: 2026-05-25
linked-artifacts:
  - DESIGN-001
depends-on-artifacts: []
evidence-pool: async-subagent-dispatch@5ca7b44
---

# ADR-001: Async .subagents/ lock-watch as primary dispatch mode

## Context

dispatch-opencode v1 shipped with three transport modes — ACP, CLI, and HTTP — with ACP as default. ACP was chosen because it offered native permission relay, no shell-injection surface, and standardized session lifecycle.

Experience and analysis revealed:

1. **ACP adds complexity without proportional benefit.** The ACP client requires JSON-RPC framing, initialize/newSession/prompt round-trips, permission-ask dispatch, idle detection, and crash recovery. This is ~700 lines of integration code that opencode maintains in its own ACP server — we are duplicating transport logic that our dispatch target already owns.

2. **ACP's permission relay is unused.** We set `--dangerously-skip-permissions` in CLI mode and a per-kind allowlist in ACP mode. The allowlist works the same way without ACP — the skill writes constrained prompts and trusts its template. No real workload uses ACP's interactive permission relay because dispatch is fire-and-forget.

3. **No async mode.** All three transports are synchronous — the parent blocks until the subagent exits. This prevents parallel fan-out and wastes parent context while waiting.

4. **Industry pattern mismatch.** Copilot CLI uses `/delegate` + fleet orchestrator, Codex uses `run_in_background`, Antigravity ships async subagents as a headline feature. All three avoid ACP-like protocols for subagent dispatch. The industry trend is toward file-based or protocol-free async dispatch.

5. **DESIGN-001 ("dispatch-opencode v2 system contracts")** proposed layering on acpx and keeping ACP. That design assumed acpx would provide the async primitive, but acpx does not exist yet in this toolchain. We should not design around a dependency that isn't available.

## Decision

**Adopt async file-based dispatch via `.subagents/` as the primary mode.** Dispatch ACP, CLI, and HTTP modes. The new architecture:

1. **The parent writes** `prompt.md` and `script.sh` into `.subagents/<task-id>/`.
2. **The subagent creates** `.subagents/<task-id>/.lock` (with PID) on start, deletes it on completion.
3. **The subagent writes** `FINAL_OUTPUT.md` with a structured result.
4. **The parent polls** `stat .lock` — deleted means done, stale mtime means stalled.
5. **The parent reads** only `FINAL_OUTPUT.md` for the result — `stdout.log` is for troubleshooting only.

### What happens to existing modes

| Mode | Status | Rationale |
|------|--------|-----------|
| ACP | Dropped | Most complex, least used. Permission relay unused in practice. |
| CLI | Dropped | Same sync model as ACP. Async subsumes it. |
| HTTP | Dropped | Same sync model. Permission hang bug (#16367) unfixable without ACP. |
| **async** | **New primary** | File-based lock-watch. Zero protocol overhead. |

### What about --dangerously-skip-permissions?

The async mode doesn't need it. The parent writes a tightly-scoped prompt. The subagent has the same tool access as any opencode session. Permission policy is enforced by the prompt design, not a protocol layer.

### What about the permission allowlist?

Per-kind permission rules move into the prompt template (the parent writes them into the subagent's instructions). No separate allowlist data structure needed.

### What about CWD verification and on-disk artifacts?

These survive unchanged. `verify-cwd.sh` still runs before dispatch. Artifact layout under `.subagents/<task-id>/` replaces `.dispatch-opencode/<task-id>/` — same principle, shorter path.

## Alternatives Considered

### Keep ACP as primary

- Pros: No migration cost. Existing templates and tests work.
- Cons: Still sync. Still complex. Still no industry alignment. The ACP permission-relay value prop is theoretical — in practice we deny everything by default.

### Keep all modes, add async as a 4th option

- Pros: Backward compatibility.
- Cons: Four dispatch paths to maintain. The skill's SKILL.md would be even longer. ACP/CLI/HTTP have no active users — maintaining them is pure drag.

### Adopt only async, keep a sync CLI fallback for simple cases

- Pros: Simple one-off dispatches don't need the async machinery.
- Cons: The async machinery is lightweight (one directory, a lock file, a poll loop). A sync CLI fallback adds a second code path with no real benefit. The parent can always `opencode run` directly if it wants sync — dispatch-opencode doesn't need a wrapper for that.

## Consequences

### Positive

- **Async by default.** Parent dispatches and moves on. Parallel fan-out becomes trivial — poll N `.lock` files.
- **Context efficiency.** Parent reads `FINAL_OUTPUT.md` (small, structured) instead of `events.jsonl` (large, verbose).
- **Zero protocol overhead.** No JSON-RPC, no ACP client code, no permission relay state machine.
- **Stall detection is a file stat.** `stat .lock` to check liveness. No timeout wrapper.
- **Single code path.** One dispatch mode instead of three. Simpler SKILL.md, simpler tests.
- **Industry-aligned pattern.** File-based async dispatch is where Copilot, Codex, and Antigravity converge.

### Negative

- **No permission relay.** The parent cannot approve/deny individual tool calls mid-flight. Mitigation: tightly-scoped prompts and post-hoc validation.
- **No live attach.** The operator cannot `opencode attach` to a running subagent. Mitigation: the subagent runs in a real opencode session — the operator can attach manually if they know the session ID. The `--share` URL is still available.
- **New `--mode async` flag.** Existing tooling that passes `--mode acp` breaks. Mitigation: error message pointing to the new mode.
- **DESIGN-001 is superseded.** The acpx integration contract (3-hook adapter model) no longer applies. The v2 milestone shifts from "layer on acpx" to "adopt async file-based dispatch."

### Migration

1. Create `.subagents/` directory convention (`.gitignore` it).
2. Implement the async dispatcher: write prompt + script, spawn `opencode run &`, poll `.lock`, read `FINAL_OUTPUT.md`.
3. Remove ACP, CLI, HTTP dispatch code.
4. Update SKILL.md, templates, tests.
5. Supersede DESIGN-001.

## Evidence

- Trove `async-subagent-dispatch@5ca7b44` — 4 sources covering industry patterns, context packets, community skills, and async platform features (Copilot /delegate, Codex run_in_background, Antigravity).
- Field evidence: research-keeper retro (4 parallel agents, 36 rounds, 0 merge conflicts via worktree isolation).
- Session-in-session bug (issue #24747): ACP and CLI mode both trigger it when run from within opencode. Async dispatch via `.subagents/` avoids the env-var leak entirely because the parent doesn't need to inherit the child's env.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-05-25 | — | User-requested, fully developed in-session. Supersedes DESIGN-001. |
