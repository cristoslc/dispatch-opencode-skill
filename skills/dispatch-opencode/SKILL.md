---
name: dispatch-opencode
description: >
  Dispatch subagent tasks through opencode (https://opencode.ai) using the
  async .subagents/ lock-watch protocol. The agent writes a plan YAML,
  calls run-plan.sh to validate and dispatch, polls lockfiles on its own
  interval, reads FINAL_OUTPUT.md on completion, and calls
  subagent-cleanup.sh or subagent-abandon.sh to tear down. Use when you
  want to hand work off to a background subagent instead of doing it
  yourself — for example, dispatching a subagent into a worktree,
  parallelizing independent tasks, or running long-lived investigations.
  TRIGGER when: the agent would otherwise block on a subagent that could
  run in the background, or when worktree-isolated subagent dispatch is
  needed.
license: MIT
compatibility: Requires opencode CLI (https://opencode.ai), git, and a running
  `opencode serve` daemon for --attach mode (optional, falls back to local).
metadata:
  version: "2.0.0"
  status: active
  author: cristoslc
  spokes:
    - path: references/troubleshooting.md
      trigger: session not found, blank FINAL_OUTPUT.md, dispatch skipped, timeout, stuck, exit code 3, exit code 2, branch not found, orphaned symlink, worktree symlink, prompt file resolves
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
- You are the orchestrator in a sashay: the branch, worktree, and draft PR
  already exist on the forge. Use this skill to dispatch a subagent into
  the worktree with sashay chronicle instructions in the prompt. The
  subagent will commit, push, and post PR comments throughout its work.

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
4. Call `poll-subagent.sh --task-id <id> --root <path>`. It logs
   event line count each iteration, detects stuck tasks (exit 2),
   and times out (exit 3).
5. On completion (exit 0): read `FINAL_OUTPUT.md`, merge work, call
   `subagent-cleanup.sh`.
6. On failure or stuck (exit 2/3): call `subagent-abandon.sh`.

### Workflow 2: Parallelize N tasks

1. Write an N-task plan YAML (only tasks whose dependencies are
   satisfied).
2. Call `run-plan.sh --plan plan.yaml`.
3. Parse JSON output for N lockfile paths and PIDs.
4. For each dispatched task, call `poll-subagent.sh --task-id <id>
   --root <path>`. It logs event line count per iteration, detects
   stuck tasks, and times out.
5. Per completed task: read `FINAL_OUTPUT.md`, merge work, call
   `subagent-cleanup.sh`.
6. Per failed or stuck task: call `subagent-abandon.sh`.

### Workflow 3: Stale resource recovery

Call `cleanup-stale.sh [--abandon]` after a crash or long idle period.

- Without `--abandon`: reports stale locks and orphaned worktrees.
- With `--abandon`: calls `subagent-abandon.sh` for each.

## Script inventory

| Script | Agent-facing | Purpose |
|--------|-------------|---------|
| `run-plan.sh` | yes | Validate plan, prepare worktrees, dispatch, return lockfile list as JSON |
| `poll-subagent.sh` | yes | Poll subagent lockfile until completion, stuck, or timeout |
| `subagent-cleanup.sh` | yes | Remove completed task's artifacts + worktree |
| `subagent-abandon.sh` | yes | Kill PID, force-remove failed task + worktree |
| `cleanup-stale.sh` | yes | Scan for stale locks and orphaned worktrees |
| `dispatch.sh` | no (internal) | Single-task prepare, spawn, confirm .lock appeared |
| `verify-cwd.sh` | no (internal) | Fail-closed CWD verification |
| `validate-run.sh` | no (internal) | Post-hoc event stream validation |

## Plan schema

```yaml
dangerously_write_trunk: false   # optional. Set true to allow dispatch to main/master.
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    worktree: fix-auth-branch     # optional. Branch name for worktree creation.

  - id: refactor-api
    kind: multi-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/refactor-api.md
    worktree: refactor-api-branch # optional
```

Fields: `id` (required), `kind` (required), `model` (required),
`prompt` (required, path to prompt file), `target` (required for
single-file-fix, path inside cwd; not used for multi-file-fix),
`worktree` (optional, branch name), `agent` (optional, defaults per kind).

Top-level field `dangerously_write_trunk` (optional, default `false`):
when `false`, dispatch to a trunk branch (main/master) is rejected with
a hint to set this flag. Set to `true` to allow dispatching directly to
the project root — use only when you are certain the subagent should
write to trunk.

Store prompt files in `prompts/<task-id>.md` at the project root.
For example, a plan referencing `prompt: prompts/fix-auth.md` has the
prompt file at `<project>/prompts/fix-auth.md` and the task directory
at `<project>/.subagents/fix-auth/`.

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

## poll-subagent.sh

```
poll-subagent.sh --task-id <id> --root <project-root> \
  [--interval <sec>] [--max-polls <n>] [--stale-threshold <sec>]
```

Monitors a dispatched subagent by polling its lockfile and `events.jsonl`.
Each iteration logs the event line count and mtime. Exits with:

- **0** — task completed (lockfile gone)
- **2** — stuck (events line count unchanged and mtime stale past threshold)
- **3** — timeout (max polls reached, lockfile still present)
- **1** — error (bad args, missing task dir)

Defaults: `--interval 15`, `--max-polls 12` (up to 180s),
`--stale-threshold 60`. Use `--max-polls 16` for complex tasks (up to 240s).

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
| `multi-file-fix` | **available** | Full-directory fix/refactor with no single-file target. Works on the entire CWD. No `target` needed. |
| `headless-spike` | **available** | Read-only investigation; agent writes a report file but does not edit source. Required: `target` (report path). Defaults to `--agent explore` (opencode's read-only built-in). |

## Sashay dispatch pattern

In a sashay, the calling agent has already created the branch, worktree, and draft PR. The calling agent then dispatches a subagent into the existing worktree using this skill. The calling agent includes chronicle instructions (commit, push, post PR comments) directly in the prompt file — the subagent follows them.

The subagent's `--cwd` must point to the worktree directory, not the project root. Use `multi-file-fix` with `worktree` pointing to an existing branch name. The skill creates a worktree from that branch and sets CWD to it automatically.

Example plan YAML from the calling agent:

```yaml
tasks:
  - id: implement-fix
    kind: multi-file-fix
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/implement-fix.md
    worktree: fix-branch-name
```

The prompt file (`prompts/implement-fix.md`) includes the sashay chronicle instructions:

```markdown
You are working in a PR-tracked worktree. The draft PR URL is
https://github.com/org/repo/pull/123.

Chronicle rules:
1. Commit and push your changes regularly.
2. After each checkpoint, add a PR comment via the forge CLI.
3. When done, ensure all tests pass and signal completion.
```

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

## opencode CLI syntax reference

Commands and flags relevant to dispatch-opencode. Full docs at
<https://opencode.ai/docs/cli/>.

### Global flags

| Flag | Description |
|------|-------------|
| `--help` / `-h` | Display help |
| `--version` / `-v` | Print version number |
| `--print-logs` | Print logs to stderr |
| `--log-level` | DEBUG, INFO, WARN, ERROR |
| `--pure` | Run without external plugins |

### `opencode run`

Non-interactive prompt execution — the core invocation for subagent
dispatch. Pass a prompt via stdin or as arguments.

```
opencode run [message..]
```

```
opencode run < prompt.md
```

#### Flags

| Flag | Description |
|------|-------------|
| `--model` / `-m` | `provider/model` — e.g. `ollama-cloud/deepseek-v4-flash:cloud` |
| `--agent` | Agent to use: `build` (default), `explore` (read-only), or a custom agent |
| `--attach` | Attach to a running server — e.g. `--attach http://localhost:4096` |
| `--password` / `-p` | Basic auth password (defaults to `OPENCODE_SERVER_PASSWORD`) |
| `--username` / `-u` | Basic auth username (defaults to `OPENCODE_SERVER_USERNAME` or `opencode`) |
| `--dir` | Working directory (or path on remote server when attaching) |
| `--file` / `-f` | Attach file(s) to the prompt |
| `--format` | `default` (formatted) or `json` (raw JSON events) |
| `--thinking` | Show thinking blocks |
| `--continue` / `-c` | Continue the last session |
| `--session` / `-s` | Resume a specific session by ID |
| `--fork` | Fork session when continuing (use with `--continue` or `--session`) |
| `--dangerously-skip-permissions` | Auto-approve permissions not explicitly denied |
| `--title` | Title for the session |

### `opencode serve`

Headless HTTP server. Required for `--attach` mode. Set
`OPENCODE_SERVER_PASSWORD` to enable basic auth.

```
opencode serve [--port <n>] [--hostname <host>] [--mdns]
```

### `opencode models`

List available models from configured providers. Format:
`provider/model`.

```
opencode models [provider]
```

`--refresh` updates the cached model list. `--verbose` includes
cost metadata.

### `opencode auth login`

Authenticate with an LLM provider. Credentials stored at
`~/.local/share/opencode/auth.json`.

```
opencode auth login [--provider <id>] [--method <label>]
```

Provider env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.)
also work without running `auth login`.

### `opencode attach`

Attach TUI to a running server.

```
opencode attach <url> [--dir <path>] [--continue]
```

### Relevant environment variables

Dispatched subagents set these automatically (templates):

| Variable | Purpose |
|----------|---------|
| `OPENCODE_DISABLE_AUTOCOMPACT=true` | Prevent context compaction in subagent |
| `OPENCODE_DISABLE_AUTOUPDATE=true` | Prevent update checks in subagent |

Server-attach variables (set by the operator before running
`opencode serve`):

| Variable | Purpose |
|----------|---------|
| `OPENCODE_SERVER_URL` | URL of the headless server for `--attach` mode |
| `OPENCODE_SERVER_PASSWORD` | Basic auth password |
| `OPENCODE_SERVER_USERNAME` | Basic auth username (default `opencode`) |

## Troubleshooting

See `references/troubleshooting.md` for detailed
solutions to common issues. Trigger keywords: `session not found`,
`blank FINAL_OUTPUT.md`, `dispatch skipped`, `timeout`, `stuck`,
`exit code 3`, `exit code 2`, `branch not found`, `orphaned symlink`,
`worktree symlink`, `prompt file resolves`.