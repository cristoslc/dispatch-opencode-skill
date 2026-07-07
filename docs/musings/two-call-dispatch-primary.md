# Two-call dispatch as primary path

The current SKILL.md describes workflows that bundle dispatch + polling into a single linear sequence. But the scripts already support a cleaner pattern: `run-plan.sh` returns immediately with lockfile paths and PIDs, and `poll-subagent.sh` is a separate call.

The user wants this two-call pattern to be the **primary** path:

1. **Call 1: `run-plan.sh`** — dispatch N tasks, get back lockfile paths and PIDs. Returns immediately. The agent can fire off several plans in parallel.
2. **Call 2: `poll-subagent.sh`** — check in on a specific task later. The agent calls this periodically for each task it cares about.

This is already what the scripts do. The problem is the SKILL.md documentation describes workflows that bundle them together ("Parse JSON output... Call poll-subagent.sh... On completion...") as if they're a single sequential flow. The watcher daemon (Workflow 4) was an attempt to solve the "background" problem, but it adds complexity (daemon lifecycle, watch directory, plan file moves) that the user doesn't want.

What needs to change:

- **SKILL.md agent workflows** — rewrite Workflow 1 and 2 to explicitly show the two-call pattern. The agent dispatches all tasks first, then polls later. Show examples of dispatching 3 tasks in parallel, then checking in on each.
- **Demote watcher daemon** — the watcher is a secondary pattern for fire-and-forget when the agent won't be around to poll. The two-call pattern is the primary path.
- **Maybe add a `poll-all.sh`** — a convenience script that polls all active tasks in a project root and returns a summary. Not strictly needed but would make the "check in on several" pattern cleaner.

The scripts themselves don't need changes. This is a documentation and workflow description change only.

Open question: should we add a `--all` flag to poll-subagent.sh that polls all active tasks in the project root? Or keep it simple and let the agent call poll-subagent.sh in a loop?
