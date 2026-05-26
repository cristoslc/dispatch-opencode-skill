---
source-id: superpowers
title: "Community skills (mattpocock, superpowers) — subagent orchestration patterns"
type: web-articles+issues
fetched: 2026-05-25
verified: false
---

# Community subagent orchestration patterns

## mattpocock/skills

The most-starred community skills collection (~101K stars). Key pattern:

The **TDD skill** uses `context: fork` (subagent isolation) to run test-writing and implementation agents in separate contexts. This is the only built-in async mechanism — the skill file declares isolation in frontmatter and Claude Code handles the rest.

No file-based handoff. No lock files. The fork mechanism is a synchronous RPC call from the parent's perspective.

## superpowers (obra/superpowers)

Issue #469 tracks the gap: "The execution skills (executing-plans, subagent-driven-development, dispatching-parallel-agents) use a sequential subagent dispatch pattern: one subagent at a time, with the main agent as controller."

The requested improvement: leverage Claude Code's Agent Teams feature (TeamCreate, SendMessage, shared TaskList) for true parallel execution. This is closer to our proposed async pattern, but depends on experimental infrastructure (Agent Teams).

Superpowers' approach to cross-runtime compatibility is instructive:
- Detect whether the environment supports teams
- If available, offer the user the choice
- If not, fall back to sequential subagent dispatch
- Keep both paths working

This is the same principle that dispatch-opencode should follow — support both sync (current) and async (proposed) dispatch modes.

## Key takeaway

Even the most sophisticated community skills do not implement file-based async handoff. They rely on:
1. Claude Code's built-in Task tool (synchronous, isolated context)
2. Agent Teams (experimental, Claude Code only)
3. Sequential chaining with output passing via prompt arguments

A file-based lock + FINAL OUTPUT convention would be novel in this space. No established community pattern exists for it.

## Sources

- https://github.com/mattpocock/agent-rules-books
- https://github.com/obra/superpowers/issues/469
- https://www.shareuhack.com/en/posts/claude-code-community-skills-agent-fleet-guide-2026
- https://claudefa.st/blog/guide/agents/sub-agent-best-practices
