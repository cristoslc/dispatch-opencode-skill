---
source-id: async-platforms
title: "Async subagent dispatch in Copilot CLI, Codex, and Antigravity"
type: web-articles+docs
fetched: 2026-05-25
verified: false
---

# Async subagent dispatch in major platforms

Contrary to earlier findings, **async subagent dispatch exists and is a headline feature in multiple platforms.**

## Copilot CLI — `/delegate` and fleet orchestrator

Copilot CLI has two async mechanisms:

**`/delegate` command** (deepwiki.com/github/copilot-cli/3.8-async-task-delegation): Hands off a task to a background coding agent. The agent commits unstaged changes to a new branch, works in the background, creates a draft PR, and notifies you when done. Progress surfaces in the UI (current intent, completed tool calls). Hooks fire on completion. Tasks survive across sessions.

**Fleet orchestrator** (deepwiki.com/github/copilot-cli/3.6-agent-modes-and-subagents): Decomposes large tasks into parallel subtasks. Each subagent can use a different custom agent. Subagents execute concurrently. This runs locally, not in the cloud.

Both use a built-in protocol, not file-based signaling.

## Codex — `run_in_background: true`

Codex supports background subagent execution. From the Anthropic issue tracker (github.com/anthropics/claude-code/issues/50572):

> "When a subagent uses `run_in_background: true` to launch a long-running Bash command... the harness itself promoted it to an async background agent."

Codex automatically converts to async when appropriate. The report shows this is a user-facing feature, not an implementation detail.

## Antigravity CLI (Google) — async subagents as headline feature

From dev.to/arindam_1729/antigravity-cli:

> "Antigravity CLI's headline upgrade over Gemini CLI is asynchronous subagents. From inside the TUI you can dispatch a long-running task to a background agent and keep prompting in the foreground. Async subagents are a genuine workflow upgrade."

## Community signal: file-based approach attempted

From a Reddit user on r/codex (reddit.com/r/codex/comments/1s04gcg/):

> "I even tried to setup an internal signal bus system so it could read a file/sql lite showing subagents last time it did an action instead of assuming agent as dead"

This is exactly the lock-file mtime polling pattern. Someone independently arrived at the same approach, suggesting the pattern is intuitive even if not widely documented.

## Summary

| Platform | Async mechanism | Where it runs |
|----------|----------------|---------------|
| Copilot CLI | `/delegate` + built-in protocol | Cloud (GitHub Actions) |
| Copilot CLI | Fleet orchestrator + subagents | Local |
| Codex | `run_in_background: true` | Local |
| Antigravity | Built-in TUI async subagents | Local |
| dispatch-opencode | None yet | — |

## Sources

- https://deepwiki.com/github/copilot-cli/3.8-async-task-delegation
- https://deepwiki.com/github/copilot-cli/3.6-agent-modes-and-subagents
- https://github.com/anthropics/claude-code/issues/50572
- https://dev.to/arindam_1729/antigravity-cli-a-hands-on-guide-to-googles-terminal-coding-agent-5bc7
- https://github.blog/changelog/2025-10-28-github-copilot-cli-use-custom-agents-and-delegate-to-copilot-coding-agent/
- https://bartwullems.blogspot.com/2026/03/github-copilot-cli-tips-tricks-part-5.html
