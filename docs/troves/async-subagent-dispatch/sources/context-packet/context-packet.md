---
source-id: context-packet
title: "Context packet pattern — what to include in a subagent dispatch prompt"
type: web-articles
fetched: 2026-05-25
verified: false
---

# Context packet pattern

The subagent receives a tight, scoped bundle — never the full conversation history.

## What the industry includes

From chanl.blog (channel.tel/blog/claude-code-subagents-orchestrator-pattern), the canonical context packet contains:

> "Each subagent receives a context packet: the project path, its CLAUDE.md, the relevant rules file, the task description, and the commands it needs (build, test, health check). This is the most important part of the pattern, because the subagent doesn't see your conversation history. The context packet is everything it knows."

From the pries gist, a real dispatch prompt includes:
- Specific file names to read
- Exact commands to run
- Concrete acceptance criteria
- Key rules that apply

## What NOT to include

From the field experience in claudefa.st: "I have seen prompts balloon to three thousand tokens of context that the subagent ignores entirely because the task it was given only needed a file path and an instruction."

Key exclusions:
- Conversation history from the parent session
- Full CLAUDE.md (reference it instead)
- Large file contents (reference file paths — the subagent reads them)
- Intermediate reasoning from prior subagent runs

## Output format

The most productive subagents produce structured output that the parent can parse without re-reading the full log. From claudefa.st: "Scope the prompt to the task. Keep the output contract tight. Measure what comes back before building deeper workflows on top of it."

Common patterns:
- A markdown summary at a known path
- A JSON result blob with key findings, changed files, error count
- A diff or patch file
- A "verdict" line the parent can grep for

## Relationship to our current design

Our current dispatch-opencode templates already follow the context packet pattern:
- `--prompt-file` keeps the prompt separate from invocation args
- Per-kind templates scope tools and permissions tightly
- `verify-cwd.sh` ensures the subagent works in the right directory

The gap: we don't define an explicit output contract or structured result format. The parent must read the full `events.jsonl` or `stdout.log` to understand what happened.

## Sources

- https://www.channel.tel/blog/claude-code-subagents-orchestrator-pattern
- https://gist.github.com/ppries/f07fd6316bbd45807dd7a1896555b05b
- https://claudefa.st/blog/guide/agents/sub-agent-best-practices
- https://www.tembo.io/blog/claude-code-subagents
