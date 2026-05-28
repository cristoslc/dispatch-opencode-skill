# User Experience

This is a developer tool, not an end-user product. The "user" is an AI
orchestrator or a developer invoking scripts from a terminal.

## Installation

1. Copy or symlink `skills/dispatch-opencode/` into the host skill
   directory (`.claude/skills/`, `.agents/skills/`, etc.).
2. Ensure opencode, git, python3, and PyYAML are on PATH.

No build step. No configuration file required — defaults work out of the
box. No per-host adapter needed — the dispatch target is always
`opencode run` via CLI.

## UX principles

- **Explicit over implicit.** Every dispatch requires an absolute CWD.
  No defaults, no inference. If the path is wrong, the script exits
  before anything runs.
- **On-disk truth.** Every artifact (prompt, event log, final output)
  lives in `.subagents/`. The directory is the source of truth. Nothing
  is hidden in memory or environment variables.
- **Fail closed.** Verification scripts reject anything ambiguous. A
  missing branch, a wrong path, a stale lock — all are errors, not
  silent fallbacks.
- **Fire-and-forget.** The orchestrator dispatches and moves on.
  Polling is a background loop. The orchestrator does not sit idle
  waiting for one subagent to finish before starting the next.

## Key interactions

**Run plan.** Write a plan YAML listing ready tasks. Run
`run-plan.sh --plan plan.yaml`. It validates, dispatches, and returns
structured JSON. The orchestrator polls lockfiles on its own interval.

**Cleanup.** After reading `FINAL_OUTPUT.md` and merging work, call
`subagent-cleanup.sh` to remove task artifacts and worktree.

**Abandon.** If a task fails or is no longer needed, call
`subagent-abandon.sh` to kill the PID and force-remove everything.

**Attach mid-flight.** Subagent sessions are visible on the opencode
serve daemon. Attach from another terminal with
`opencode attach http://localhost:4096 --session <id>`.

## Quality attributes

| Attribute | Target |
|-----------|--------|
| Dispatch latency | Under 2 seconds from invocation to `.lock` appearance |
| Poll interval | Orchestrator's choice (recommended ~15s) |
| Parallelize overhead | Linear — N tasks start in spawn + lock-appearance time |
| Audit completeness | Every dispatch produces prompt, events, and output on disk |
| Crash recovery | Stale locks and orphaned worktrees cleaned by `cleanup-stale.sh` |

## Detail

- `docs/user-experience/` — interaction flows, error message inventory