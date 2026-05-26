# Synthesis — async subagent dispatch patterns

## Async is real and shipping in multiple platforms

Async subagent dispatch is a **headline feature** in three major platforms. It is not experimental or theoretical.

| Platform | Async mechanism | Where it runs |
|----------|----------------|---------------|
| Copilot CLI | `/delegate` + fleet orchestrator | Cloud (PRs) + Local |
| Codex | `run_in_background: true` | Local |
| Antigravity (Google) | Built-in async subagents in TUI | Local |
| dispatch-opencode | None yet | — |

Copilot CLI is the most mature: `/delegate` spawns a background agent on GitHub Actions, commits to a branch, opens a draft PR, and notifies you. The fleet orchestrator decomposes large tasks into parallel local subagents. Codex auto-promotes to async when a subagent launches long-running background work. Antigravity markets async subagents as its headline upgrade over Gemini CLI.

None of these use file-based signaling. They use built-in protocols and UI-level progress tracking.

## The file-based approach is still novel

A Reddit user independently attempted the same pattern — an SQLite/last-active-time file checked by the parent — and hit the same edge cases. This confirms the pattern is intuitive but also that no platform has solved it well at the file level.

The gap dispatch-opencode can fill: since we already dispatch via `opencode run` (a process boundary), we lack the built-in protocol that Copilot/Codex/Antigravity have. File-based signaling is the natural adaptation for the process-per-task model.

## Whether async is desirable depends on the use case

**Yes, async is desirable when:**
- The parent wants to continue working while subagents run (parallel fan-out, research tasks)
- The subagent runs for minutes/hours (large refactors, dependency upgrades)
- The parent's context window is precious and can't hold subagent logs
- The task is fire-and-forget (create a PR in the background)

**No, async doesn't help when:**
- The parent needs the subagent's result to proceed (sequential dependency)
- The subagent finishes in seconds (overhead exceeds benefit)
- The parent needs to steer or answer permission questions mid-flight

## Proposed approach: hybrid

The skill should support **both** sync (current ACP/CLI/HTTP) and async (proposed `.subagents/` file-based), selected per-dispatch:

```
--mode acp     # synchronous ACP, current behavior
--mode cli     # synchronous CLI, current behavior
--mode async   # new: file-based async via .subagents/<task-id>/
```

The async mode is the right default for `parallel-review-fanout` (N agents, no inter-agent dependencies) and for any task where the parent would otherwise wait unnecessarily.

## Key industry references (corrected)

- Copilot CLI async task delegation (deepwiki.com/github/copilot-cli/3.8-async-task-delegation)
- Codex `run_in_background: true` (github.com/anthropics/claude-code/issues/50572)
- Antigravity async subagents (dev.to/arindam_1729)
- Coordinator-subagent pattern (claude.com/blog/multi-agent-coordination-patterns)
- Context packet pattern (channel.tel)
