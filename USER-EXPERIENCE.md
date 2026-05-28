# User Experience

This is a developer tool, not an end-user product. The "user" is an AI orchestrator or a developer invoking scripts from a terminal.

## Installation

1. Copy or symlink `skills/dispatch-opencode/` into the host skill directory (`.claude/skills/`, `.agents/skills/`, etc.).
2. Copy the runtime adapter for the host (e.g., `templates/runtimes/claude-code/oc-dispatch.md` to `.claude/commands/`).
3. Ensure opencode, git, python3, and PyYAML are on PATH.

No build step. No configuration file required — defaults work out of the box.

## UX principles

- **Explicit over implicit.** Every dispatch requires an absolute CWD. No defaults, no inference. If the path is wrong, the script exits before anything runs.
- **On-disk truth.** Every artifact (prompt, event log, final output) lives in `.subagents/`. The directory is the source of truth. Nothing is hidden in memory or environment variables.
- **Fail closed.** Verification scripts reject anything ambiguous. A missing branch, a wrong path, a stale lock — all are errors, not silent fallbacks.
- **Fire-and-forget.** The orchestrator dispatches and moves on. Polling is a background loop. The orchestrator does not sit idle waiting for one subagent to finish before starting the next.

## Key interactions

**Single dispatch.** Run `dispatch.sh` with kind, CWD, model, agent, prompt, and target. The script spawns a background subagent and polls the lock file. When the lock disappears, read `FINAL_OUTPUT.md`.

**Parallelize.** Write a plan YAML listing ready tasks. Run `orchestrate.sh --plan plan.yaml`. It dispatches all tasks in parallel, polls for completion, and aggregates results.

**Worktree isolation.** Before dispatching to a shared repo, call `worktree-prepare.sh` to create an isolated branch. After the subagent completes, call `worktree-complete.sh` or `worktree-abandon.sh`.

**Attach mid-flight.** Subagent sessions are visible on the opencode serve daemon. Attach from another terminal with `opencode attach http://localhost:4096 --session <id>`.

## Quality attributes

| Attribute | Target |
|-----------|--------|
| Dispatch latency | Under 2 seconds from invocation to `.lock` appearance |
| Poll interval | 2 seconds |
| Parallelize overhead | Linear — N tasks start in N × (spawn + lock-appearance) time |
| Audit completeness | Every dispatch produces prompt, events, and output on disk |
| Crash recovery | Stale locks detected by `cleanup-stale.sh`; orphaned worktrees cleaned by `worktree-abandon.sh` |

## Detail

- `docs/user-experience/` — interaction flows, error message inventory