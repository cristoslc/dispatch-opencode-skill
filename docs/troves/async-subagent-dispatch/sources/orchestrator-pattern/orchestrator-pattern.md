---
source-id: orchestrator-pattern
title: "Subagent orchestrator patterns — industry consensus on coordinator-subagent architecture"
type: web-articles
fetched: 2026-05-25
verified: false
---

# Subagent orchestrator patterns

Industry-wide consensus on how multi-agent systems route work through a central coordinator.

## Coordinator-subagent is the universal pattern

Anthropic's own guide (claude.com/blog/multi-agent-coordination-patterns, 2026) describes the orchestrator-subagent pattern as the foundation: "A lead agent receives a task and determines how to approach it. It may handle some subtasks directly while dispatching others to subagents."

Every major implementation follows this:

- **Claude Code** — the Task tool spawns a subagent. "A new context window, initialized from scratch, given only what was passed in the prompt argument." (medium.com/@neonmaxima)
- **dispatch-opencode** (our skill) — ACP/CLI mode spawns opencode per task.
- **OpenAgentsControl** (github.com/darrenhinde/OpenAgentsControl) — 7 specialized subagents with "Only load what's needed, when it's needed."
- **pries gist** (gist.github.com/ppries) — "plan, review, implement, PR from a Linear issue" pipeline with purpose-built agents with constrained tool access.

## Three execution modes

From claudefa.st/blog/guide/agents/sub-agent-best-practices:

| Mode | When | Pattern |
|------|------|---------|
| Parallel | 3+ unrelated tasks, no shared state, clear file boundaries | Fan-out, wait for all, merge |
| Sequential | Tasks have dependencies, shared files, unclear scope | Chain, pass output to next |
| Background | Research/analysis, results not blocking current work | Fire-and-forget, poll for completion |

The background mode is the least documented and least supported. Most implementations default to sequential, with parallel as an explicit opt-in.

## Context isolation is the key property

The subagent gets its own context window, initialized from scratch. From cefboud.com/posts/coding-agents-internals-opencode-deepdive: "A new session is created for the subagent, spun up by the primary agent. The subagent gets its own tools and system prompt, and runs in its own context window — possibly even with a different LLM."

This means:
- No accumulated assumptions from the main session
- No context pollution from prior turns
- Each subagent starts clean
- The orchestrator must pass everything the subagent needs explicitly

## Output contracts

The best patterns define an explicit output schema. From mindstudio.ai: "Define the schema explicitly in the sub-agent instructions and have the orchestrator validate outputs during merge."

The coordinator validates:
- Did the subagent return the expected structure?
- Did it edit the expected files?
- Did it hit any errors?

## Stale lock / crash recovery gap

No established pattern handles subagent crashes cleanly. The industry relies on:
- The coordinator detecting a timeout and re-dispatching
- Human operator noticing stalled work
- Retry-on-failure logic in the coordinator's prompt

There is no file-based lock-with-keepalive pattern documented anywhere in the searched sources.

## Sources

- https://claude.com/blog/multi-agent-coordination-patterns
- https://claudefa.st/blog/guide/agents/sub-agent-best-practices
- https://claudefa.st/blog/guide/agents/agent-patterns
- https://medium.com/@neonmaxima/claude-code-subagents-how-the-task-tool-actually-distributes-work-e5fe19f48584
- https://cefboud.com/posts/coding-agents-internals-opencode-deepdive/
- https://www.mindstudio.ai/blog/claude-code-split-and-merge-pattern-sub-agents
- https://dev.to/ajbuilds/the-coordinator-subagent-pattern-the-foundation-every-claude-multi-agent-system-is-built-on-17o6
- https://github.com/darrenhinde/OpenAgentsControl
- https://gist.github.com/ppries/f07fd6316bbd45807dd7a1896555b05b
