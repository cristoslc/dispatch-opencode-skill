---
name: dispatch-opencode
description: >
  Dispatch subagent tasks through opencode (https://opencode.ai) using the
  async .subagents/ lock-watch protocol. The agent writes a plan YAML,
  calls run-plan.sh to validate and dispatch, polls lockfiles on its own
  interval, reads FINAL_OUTPUT.md on completion, and calls
  subagent-cleanup.sh or subagent-abandon.sh to tear down. Use when the
  agent wants to parallelize independent tasks with per-task worktree
  isolation and multi-model dispatch. TRIGGER when: the agent would
  otherwise block on a subagent that could run in the background, or when
  parallelize with per-task isolation is needed.
license: MIT
compatibility: Requires opencode CLI (https://opencode.ai), git, and a running
  `opencode serve` daemon for --attach mode (optional, falls back to local).
metadata:
  version: "2.0.0"
  status: active
  author: cristoslc
---

# dispatch-opencode

Routes subagent dispatch through opencode using async file-based signaling.
The skill does NOT implement ACP (Agent Client Protocol) or HTTP serve mode —
those were dropped per ADR-001. Instead, it uses CLI `opencode run` as the
invocation transport, wrapped in a `.subagents/` lock-watch protocol.

For previous versions of this skill (ACP/CLI/HTTP), see ADR-001.

## When to use

- The task takes long enough that the agent should not block (refactors,
  dependency upgrades, research sprints).
- The agent wants to parallelize N independent tasks with per-task worktree
  isolation.
- The agent wants per-task model selection (e.g., cheap model for fixes,
  capable model for design).
- The operator wants to attach to a running subagent from another terminal.
- The agent wants the dispatch artifact (prompt, event log, lock file) on
  disk for replay or audit.

## When NOT to use

- The task is trivial and finishes in seconds — the lock-watch overhead
  exceeds any benefit. Use `opencode run` directly.
- The host runtime forbids spawning background subprocesses.

## Four design constraints (non-negotiable)

1. **Every dispatch takes an explicit absolute path; verification fails
   closed.** No defaults, no inference. If the path is wrong, the
   script exits non-zero before anything runs.

2. **Every handoff is an on-disk artifact.** Every dispatch writes the
   prompt, start script, event log, and lock file under
   `.subagents/<task-id>/`. The task directory is the source of truth for
   replay and audit.

3. **One template per dispatch kind.** Templates are typed by what the
   dispatch is *for* (e.g., `single-file-fix`, `headless-spike`), not
   parameterized into a single megatemplate.

4. **Smart orchestrator, dumb subagents.** The agent decides what is
   ready and fires only ready tasks. The skill dispatches what it is
   given. Subagents are single-responsibility and should work on the
   cheapest model that can do the job. The agent continues running,
   polls, and kicks off the next wave. Subagents never coordinate with
   each other or trigger subsequent work.

## Agent workflows

### Workflow 1: Single task

1. Write a 1-task plan YAML.
2. Call `run-plan.sh --plan plan.yaml`.
3. Parse JSON output for lockfile path and PID.
4. Poll lockfile on agent's interval (~15s).
5. On completion: read `FINAL_OUTPUT.md`, merge work, call
   `subagent-cleanup.sh`.
6. On failure: call `subagent-abandon.sh`.

### Workflow 2: Parallelize N tasks

1. Write an N-task plan YAML (only tasks whose dependencies are
   satisfied).
2. Call `run-plan.sh --plan plan.yaml`.
3. Parse JSON output for N lockfile paths and PIDs.
4. Poll all lockfiles on agent's interval.
5. Per completed task: read `FINAL_OUTPUT.md`, merge work, call
   `subagent-cleanup.sh`.
6. Per failed task: call `subagent-abandon.sh`.

### Workflow 3: Stale resource recovery

Call `cleanup-stale.sh [--abandon]` after a crash or long idle period.

- Without `--abandon`: reports stale locks and orphaned worktrees.
- With `--abandon`: calls `subagent-abandon.sh` for each.

## Script inventory

| Script | Agent-facing | Purpose |
|--------|-------------|---------|
| `run-plan.sh` | yes | Validate plan, prepare worktrees, dispatch, return lockfile list as JSON |
| `subagent-cleanup.sh` | yes | Remove completed task's artifacts + worktree |
| `subagent-abandon.sh` | yes | Kill PID, force-remove failed task + worktree |
| `cleanup-stale.sh` | yes | Scan for stale locks and orphaned worktrees |
| `dispatch.sh` | no (internal) | Single-task prepare, spawn, confirm .lock appeared |
| `verify-cwd.sh` | no (internal) | Fail-closed CWD verification |
| `validate-run.sh` | no (internal) | Post-hoc event stream validation |

## Plan schema

```yaml
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    worktree: fix-auth-branch     # optional. Branch name for worktree creation.
```

Fields: `id` (required), `kind` (required), `model` (required),
`prompt` (required, path to prompt file), `target` (required for
single-file-fix, path inside cwd), `worktree` (optional, branch name),
`agent` (optional, defaults per kind).

No `depends` field. The agent writes only tasks that are ready to run
right now.

## Structured output from run-plan.sh

run-plan.sh returns JSON on stdout (all other output goes to stderr):

```json
{
  "plan_id": "20260528T151600Z",
  "tasks": [
    {
      "id": "fix-auth",
      "lockfile": "/abs/path/.subagents/fix-auth/.lock",
      "task_dir": "/abs/path/.subagents/fix-auth",
      "pid": 48912,
      "worktree": "/abs/path/.worktrees/fix-auth",
      "status": "dispatched"
    },
    {
      "id": "fix-api",
      "status": "skipped",
      "reason": "worktree creation failed: branch already exists"
    }
  ]
}
```

## Directory structure

```
<project-root>/
  .subagents/
    <task-id>/
      prompt.md
      start-subagent.sh
      .lock                ← exists while subagent runs
      events.jsonl
      FINAL_OUTPUT.md
      worktree/            ← real git worktree (if task declared one)
  .worktrees/
    <task-id>             ← symlink → ../.subagents/<task-id>/worktree/
```

`.subagents/` is gitignored. The real worktree lives inside the task
directory so its lifecycle is bound to the task. The symlink in
`.worktrees/` lets other tooling discover active worktrees.

## subagent-cleanup.sh

```
subagent-cleanup.sh --task-id <id> --root <project-root>
```

Removes .lock, removes .worktrees/ symlink, git worktree removes the
real tree (no force — should be clean after merge), removes task dir.

## subagent-abandon.sh

```
subagent-abandon.sh --task-id <id> --root <project-root>
```

Kills PID (TERM then KILL), removes .lock, removes .worktrees/ symlink,
force-removes worktree + deletes branch, removes task dir.

## Permission model

The async mode does not use ACP permission relay. Permission policy is
enforced by:

1. **Prompt design** — the agent writes a tightly-scoped prompt that
   constrains the subagent's behaviour.
2. **Config gating** — the consumer project's `opencode.json` can set
   per-command rules.
3. **Post-hoc validation** — `scripts/validate-run.sh` checks
   `events.jsonl` for unexpected tool calls.

## Default failure-mode mitigations

- `OPENCODE_DISABLE_AUTOCOMPACT=true` set in the start script.
- `OPENCODE_DISABLE_AUTOUPDATE=true` set in the start script.
- Auto-detects server mode. When `OPENCODE_SERVER_URL` is set, the
  template uses `--attach`. When unset, falls back to local `--dir`
  mode. Avoids session-in-session env-var leak (issue #24747).
- `cleanup-stale.sh` — cleans up stale `.lock` files and orphaned
  worktrees whose PIDs are dead.

## Dispatch kinds

| Kind | Status | Use for |
|------|--------|---------|
| `single-file-fix` | **available** | One agent edits one file from a focused prompt. Required: `target`. |
| `headless-spike` | **available** | Read-only investigation; agent writes a report file but does not edit source. Required: `target` (report path). Defaults to `--agent explore` (opencode's read-only built-in). |

Add a kind by:

1. Drop a `<kind>.sh.j2` in `templates/cli/`.
2. Add a row to the table above.
3. Add an example invocation to `references/examples.md`.

## What this skill does NOT do

- Run inside an editor as an ACP agent. Editor flows should call
  `opencode acp` directly.
- Expose opencode via MCP. opencode is an MCP client only.
- Manage opencode authentication. Run `opencode auth login` separately.
- Coordinate between parallel agents beyond per-task isolation and
  shared `.subagents/` directory. The agent owns all coordination.
- Merge worktree results. The agent decides merge semantics (commit, PR,
  squash, etc.).

## References

- ADR-001: async `.subagents/` lock-watch as primary dispatch mode.
- Trove: `async-subagent-dispatch@5ca7b44` — async dispatch patterns.
- Trove: `opencode-runtime-integration@d9bad44` — failure-mode catalogue.
- SPIKE-001: `--attach` session visibility on serve daemon.
- Examples: `references/examples.md`.