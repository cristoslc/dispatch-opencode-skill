---
title: "Async .subagents/ lock-watch as primary dispatch mode; drop ACP and HTTP"
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

**Adopt async file-based dispatch via `.subagents/` as the primary mode.** Drop ACP and HTTP transports; keep CLI as the invocation mechanism and wrap it in an async lock-watch protocol.

The architecture:

1. **The parent writes** `prompt.md` and `start-subagent.sh` (an `opencode run` invocation) into `.subagents/<task-id>/`.
2. **The parent spawns** the script in the background (`bash start-subagent.sh &`), capturing PID.
3. **The subagent** (`opencode run`) creates `.subagents/<task-id>/.lock` (with PID) on start, deletes it on completion.
4. **The parent polls** `stat .lock` — deleted means done, stale mtime means stalled.
5. **The parent reads** only `FINAL_OUTPUT.md` for the result — `stdout.log` is for troubleshooting only.

### What happens to existing modes

| Mode | Status | Rationale |
|------|--------|-----------|
| ACP | Dropped | Most complex, least used. Permission relay unused in practice. |
| HTTP | Dropped | Same sync model. Permission hang bug (#16367) unfixable without ACP. |
| CLI | **Kept as transport** | `opencode run` is the invocation mechanism. Wrapped in async lock-watch protocol. |
| **async CLI** | **New primary** | CLI transport + `.subagents/` signaling + lock-watch polling. |

### How the async wrapper works

The parent no longer blocks on process exit. Instead:

1. Write the dispatch script to `.subagents/<task-id>/start-subagent.sh` (same `opencode run` invocation as today, but the script writes `.lock` on start and deletes it on exit).
2. Spawn: `bash .subagents/<task-id>/start-subagent.sh &`
3. Poll loop: `test -f .subagents/<task-id>/.lock` — while it exists, the subagent is running.
4. Stall detection: if `.lock` mtime is older than the timeout threshold, kill the process and mark as stalled.
5. Completion: lock deleted → read `FINAL_OUTPUT.md`.

The parent never reads `stdout.log` unless `FINAL_OUTPUT.md` indicates a problem. `events.jsonl` is still written for post-mortem debugging.

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

### Adopt only async, drop ACP and HTTP while keeping CLI transport

- Pros: Single invocation mechanism (CLI). Async wrapping adds minimal overhead. CLI is the simplest, most widely used transport.
- Cons: `--dangerously-skip-permissions` is still needed (but we already use it). No live attach via ACP's embedded server (but `--share` URL still works).

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
