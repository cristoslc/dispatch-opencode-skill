# Synthesis — async subagent dispatch patterns

## The gap

Every major subagent implementation (Claude Code Task tool, opencode ACP/CLI, community skills) uses **synchronous dispatch** — the parent blocks until the subagent completes. This works, but costs context: the parent must either wait (wasting time) or keep the subagent's verbose output in its window (wasting tokens).

There is **no established file-based async handoff pattern** in the community. Even mattpocock/skills (~101K stars) and superpowers rely on synchronous subagent calls or experimental Agent Teams. A lock-file + FINAL OUTPUT convention would be novel.

## The three dispatch modes

| Mode | Current support | Proposed addition |
|------|----------------|-------------------|
| Sequential (chain) | Full (ACP/CLI/HTTP) | Unchanged |
| Parallel (fan-out) | ACP-only `parallel-review-fanout` | Would benefit from lock-file polling |
| Background (async) | None | New: `.subagents/` + lock + FINAL OUTPUT |

## Proposed contract

This is the "best approach" synthesized from industry patterns and our gaps:

### Directory structure

```
.subagents/<task-id>/
  script.sh        # The actual invocation script (parent writes)
  prompt.md        # The prompt body (parent writes)
  .lock            # Created by subagent on start, deleted on completion
  stdout.log       # Captured stdout (subagent writes, parent reads on trouble)
  FINAL_OUTPUT.md  # Structured result (subagent writes, parent reads for result)
```

### Flow

1. **Parent** creates `.subagents/<task-id>/` and writes `script.sh` + `prompt.md`
2. **Parent** writes the script (e.g., `opencode run --dir ... < prompt.md > stdout.log && cp result.md FINAL_OUTPUT.md`)
3. **Subagent** writes `.lock` on start (with PID), deletes it on completion
4. **Parent** polls: `stat .lock` — if `.lock` mtime is stale (> threshold), mark as stalled
5. **Parent** detects completion: `.lock` deleted, reads `FINAL_OUTPUT.md` (small, deterministic)
6. **Parent** reads `stdout.log` only if `FINAL_OUTPUT.md` indicates a problem

### Context efficiency win

| Operation | Current (sync) | Proposed (async) |
|-----------|---------------|-------------------|
| Check if done | Block on process | `test -f .lock` — no context |
| Get result | Read full `events.jsonl` | Read `FINAL_OUTPUT.md` — fixed size |
| Troubleshoot stall | Wait for timeout | `stat .lock` mtime — no context |
| Debug failure | Re-run with verbose | Optionally read `stdout.log` |

### Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| Stale lock from crash | Include PID in `.lock`; parent checks `kill -0 <pid>` |
| Missing `.lock` (subagent never started) | Parent sets initial `.lock` with `pid=0` before launch; if still `pid=0` after N seconds, mark as failed |
| `.lock` deleted but no `FINAL_OUTPUT` | Edge case — subagent deleted lock but crashed before writing output. Parent waits a grace period, then reads `stdout.log` |
| Log growth | Keep `stdout.log` but truncate at a reasonable max; `FINAL_OUTPUT.md` stays small |
| Concurrency | Limit parallel subagents with a semaphore; use worktree isolation per task |

### What to include in the prompt (context packet)

| Include | Don't include |
|---------|---------------|
| Task description and acceptance criteria | Parent's conversation history |
| Project path and CLAUDE.md reference | Full CLAUDE.md content |
| Specific file paths to read | Full file contents (subagent reads them) |
| Exact commands to run | Parent's intermediate reasoning |
| Output format specification (FINAL_OUTPUT schema) | Results from other subagents |

## What this means for dispatch-opencode

The skill should support **three dispatch modes**:

- `--mode acp` — existing ACP mode, synchronous per-kind dispatch
- `--mode cli` — existing CLI mode, synchronous per-task dispatch
- `--mode async` (new) — file-based async dispatch via `.subagents/`

The `async` mode replaces the Jinja2 template rendering with direct parent writes to `script.sh`, making the parent responsible for the prompt + invocation format. This is a deliberate tradeoff: less abstraction, but zero template overhead and complete control.

The `parallel-review-fanout` kind would benefit most — N agents run in background, the parent polls their `.lock` files, collects `FINAL_OUTPUT.md` from each, and merges.

## Key industry references

- Coordinator-subagent pattern (claude.com/blog/multi-agent-coordination-patterns) — the universal architecture
- Context packet pattern (channel.tel) — exactly what to pass to a subagent
- claudefa.st three-mode dispatch matrix — parallel vs sequential vs background
- superpowers issue #469 — the only documented attempt at async dispatch, but Agent Teams dependent
- Our own field evidence (research-keeper retro) — 4 parallel agents, 36 rounds, 0 merge conflicts via worktree isolation
