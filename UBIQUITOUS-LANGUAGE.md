# Ubiquitous Language

Terms used consistently across this project. Organized by bounded context.

## Dispatch context

**Orchestrator.** The AI agent that decides which tasks are ready, fires
them, polls for results, and kicks off the next wave. The orchestrator is
smart — it owns all coordination logic. The skill scripts never make
scheduling decisions.

**Subagent.** A single `opencode run` process spawned in the background
by the skill. Subagents are dumb — they do one thing, report via
`FINAL_OUTPUT.md`, and exit. They never coordinate with each other or
trigger subsequent work.

**Dispatch.** The act of sending a task to a subagent via `dispatch.sh`.
Includes: verifying CWD, allocating a task directory, rendering a start
script, spawning it, and confirming `.lock` appeared.

**Task directory.** `.subagents/<task-id>/`. Contains the prompt, start
script, lock file, event stream, and final output. The task directory is
the source of truth for audit and replay.

**Lock file.** `.subagents/<task-id>/.lock`. Contains the PID of the
running subagent. Exists while the subagent is live; deleted on
completion. The orchestrator polls this file — if it disappears, the
subagent is done; if its mtime is stale, the subagent is hung.

**Dispatch kind.** A template-driven category that defines what the
subagent does. Current kinds: `single-file-fix` (one agent edits one
file) and `headless-spike` (read-only investigation, writes a report).
Add kinds by dropping a `<kind>.sh.j2` in `templates/cli/`.

**CWD verification.** Fail-closed check that the working directory is an
absolute path inside a git work tree. Enforced by `verify-cwd.sh`
before every dispatch.

**Run plan.** 1-to-N parallelize via `run-plan.sh`. Reads a plan YAML
with N tasks, validates it, prepares worktrees, dispatches each via
`dispatch.sh`, and returns structured JSON. The plan contains only
ready tasks — no dependency graph.

**Plan.** A YAML file listing tasks that are ready to run right now.
Each task specifies: id, kind, model, agent, prompt file, target, and
optional worktree branch. No `depends` field.

**Result collection.** Reading `FINAL_OUTPUT.md` from each task
directory after completion. The orchestrator reads each file directly —
no aggregation script needed.

## Worktree context

**Worktree.** A git worktree created under `.subagents/<task-id>/worktree/`
for dispatch isolation, with a symlink at `.worktrees/<task-id>/`. Each
subagent operates on its own branch so parallel edits never conflict.

**Cleanup.** Remove a completed task's artifacts and worktree via
`subagent-cleanup.sh`. Removes .lock, symlink, git worktree, and task
directory. No force — the worktree should be clean after merge.

**Abandon.** Kill and force-remove a failed task via
`subagent-abandon.sh`. Terminates the PID, force-removes worktree and
branch, deletes the task directory.

## Avoid

- **Fan-out.** Use "parallelize" instead. Fan-out implies a specific
  topology; this skill parallelizes N independent tasks.
- **ACP.** Dropped. Do not refer to ACP (Agent Client Protocol) as an
  active transport. It was removed per ADR-001.
- **Permission relay.** The skill does not relay permission asks. Use
  "prompt-driven permission scoping" instead.
- **Orchestrate.** Use "run plan" instead. The skill does not
  orchestrate — it executes a plan. The orchestrator is the agent.