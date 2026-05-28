---
name: dispatch-opencode
description: >
  Dispatch a subagent task through opencode (https://opencode.ai) using the
  async .subagents/ lock-watch protocol. The parent writes a prompt and a
  start-subagent.sh script into a task directory, spawns it in the background,
  and polls a .lock file for completion. The subagent uses --attach to connect
  to a central serve daemon, keeping sessions visible for operator attach.
  Use when the parent wants async dispatch (fire-and-forget), parallel fan-out
  across N files, or auditable on-disk dispatch artifacts. TRIGGER when: the
  parent agent would otherwise block on a subagent that could run in the
  background, or when parallel fan-out with per-task isolation is needed.
license: MIT
compatibility: Requires opencode CLI (https://opencode.ai), git, and a running
  `opencode serve` daemon for --attach mode (optional, falls back to local).
metadata:
  version: "1.0.0"
  status: draft
  author: cristoslc
---

# dispatch-opencode

Routes subagent dispatch through opencode using async file-based signaling.
The skill does NOT implement ACP (Agent Client Protocol) or HTTP serve mode —
those were dropped per ADR-001. Instead, it uses CLI `opencode run` as the
invocation transport, wrapped in a `.subagents/` lock-watch protocol.

For previous versions of this skill (ACP/CLI/HTTP), see ADR-001.

## When to use

- The task takes long enough that the parent should not block (refactors,
  dependency upgrades, research sprints).
- The task fans out across N independent files or repos and needs per-task
  isolation.
- The operator wants to attach to a running subagent from another terminal.
- The operator wants the dispatch artifact (prompt, event log, lock file) on
  disk for replay or audit.

## When NOT to use

- The task is trivial and finishes in seconds — the lock-watch overhead
  exceeds any benefit. Use `opencode run` directly.
- The host runtime forbids spawning background subprocesses.

## Three design constraints (non-negotiable)

1. **The skill owns the working directory.** Every dispatch takes an explicit
   absolute path; the skill verifies the path exists and is a git work tree.
   **Verification fails closed** — no defaults, no inference.

2. **Handoffs are on-disk artifacts.** Every dispatch writes the prompt,
   start script, event log, and lock file under `.subagents/<task-id>/`.
   The task directory is the source of truth for replay and audit.

3. **One template per dispatch kind.** Templates are typed by what the
   dispatch is *for* (e.g., `single-file-fix`, `headless-spike`), not
   parameterized into a single megatemplate.

## Required arguments

| Flag | Required | Type | Description |
|------|----------|------|-------------|
| `--kind` | yes | enum | `single-file-fix` or `headless-spike`. |
| `--cwd` | yes | absolute path | Working directory; must pass `verify-cwd.sh`. |
| `--branch` | no | string | Expected branch name; verified against `git branch --show-current`. |
| `--worktree` | no | label | Expected worktree label; requires `--worktree-root`. |
| `--worktree-root` | conditional | absolute path | Worktree-root prefix; required when `--worktree` is set. |
| `--model` | yes | `provider/model` | opencode model string (e.g. `ollama-cloud/glm-5.1`). |
| `--agent` | yes | string | opencode agent name (`build`, `general`, `explore`). |
| `--target-file` | conditional | path | Required by `single-file-fix`. Path inside `--cwd`. |
| `--prompt-file` | yes | path | Path to a markdown prompt file; copied into the task dir. |
| `--timeout` | no | seconds | Per-dispatch timeout. Defaults to `default_timeout_sec` in config. |

## Dispatch flow

The preferred entry point is `scripts/dispatch.sh`, which automates the entire flow.
The manual flow (for custom orchestration):

1. **Parse intent** — kind, model, agent, target file, prompt body, CWD.
2. **Verify CWD** — `scripts/verify-cwd.sh <path> [--branch <name>] [--worktree <label> --worktree-root <absolute-root>]`.
3. **Allocate task ID** — `<UTC-timestamp>-<short-hash-of-prompt>`. Create `.subagents/<task-id>/`.
4. **Copy prompt** — write prompt text to `.subagents/<task-id>/prompt.md`.
5. **Render start script** — render `templates/cli/<kind>.sh.j2` to `.subagents/<task-id>/start-subagent.sh` with model, agent, target file, and timeout.
6. **Detect server URL** — check `OPENCODE_SERVER_URL`. If set, the template uses `--attach` so the subagent is visible on the serve daemon. If unset, the template unsets `OPENCODE_SERVER_PASSWORD` and uses local `--dir` mode (safe fallback).
7. **Spawn** — `bash .subagents/<task-id>/start-subagent.sh &`. Capture PID.
8. **Wait for .lock** — the subagent writes `.lock` on start. Wait up to 7.5s for it to appear (handles spawn-to-lock race).
9. **Poll loop** — `while [ -f .subagents/<task-id>/.lock ]; do sleep 2; done`. The `.lock` file contains the PID — the parent checks mtime every iteration for stall detection.
10. **Stall detection** — if `.lock` mtime exceeds `--timeout`, kill the process and mark the task as stalled.
11. **Read result** — read `FINAL_OUTPUT.md` for the structured result (exit code, session ID, assistant text). If absent or empty, check `events.jsonl` for the last event (error or stop reason).

### dispatch.sh

`scripts/dispatch.sh <kind> <cwd> <model> <agent> <prompt-file> <target-or-report> [--timeout <sec>]`

Handles template rendering, spawning, lock polling, and result reading automatically.
Exit codes: 0 (success), 124 (timeout/stall), 1 (error).

The parent never reads `stdout.log` unless `FINAL_OUTPUT.md` indicates a
problem. `events.jsonl` is always written for post-mortem debugging.

### Parallel fan-out

For N independent tasks, spawn N subagents in parallel — one per task directory.
Poll all `.lock` files in a loop:

```
for task in "${TASK_DIRS[@]}"; do
  bash "$task/start-subagent.sh" &
done
while true; do
  remaining=()
  for task in "${TASK_DIRS[@]}"; do
    [ -f "$task/.lock" ] && remaining+=("$task")
  done
  [ "${#remaining[@]}" -eq 0 ] && break
  sleep 2
done
```

## Permission model

The async mode does not use ACP permission relay. Permission policy is
enforced by:

1. **Prompt design** — the parent writes a tightly-scoped prompt that constrains the subagent's behaviour.
2. **Config gating** — the consumer project's `opencode.json` can set per-command rules (see below).
3. **Post-hoc validation** — `scripts/validate-run.sh` checks `events.jsonl` for unexpected tool calls.

There is no separate allowlist data structure. The ACP permission handler
(per-kind allowlist, bash-readonly HTTP probe) was removed — it only existed
to gate ACP's permission-ask protocol, which is no longer used.

For defense-in-depth, configure permissive rules in the consumer project's
`opencode.json`:

```json
{
  "permission": {
    "bash": {
      "git status *":   "allow",
      "git diff *":     "allow",
      "git log *":      "allow",
      "ls *":           "allow",
      "cat *":          "allow",
      "rm *":           "deny",
      "*":              "ask"
    }
  }
}
```

## Default failure-mode mitigations

- `--timeout <SLA>` enforced by the poll loop on the parent side.
- `OPENCODE_DISABLE_AUTOCOMPACT=true` set in the start script — avoids silent exit on compaction overflow (issue #13946).
- `OPENCODE_DISABLE_AUTOUPDATE=true` set in the same env — keeps unattended runs deterministic.
- **Auto-detects server mode.** When `OPENCODE_SERVER_URL` is set, the template uses `--attach $OPENCODE_SERVER_URL --password $OPENCODE_SERVER_PASSWORD`. When unset, falls back to local `--dir` mode. This avoids the session-in-session env-var leak (issue #24747) and keeps sessions visible for operator attach (SPIKE-001).
- `scripts/cleanup-stale.sh` — cleans up `.lock` files whose PID no longer exists (dead process without cleanup).
- For Kimi K2: route via `@ai-sdk/openai-compatible` rather than the built-in `openrouter` provider (issue #1329).

## Configuration

Defaults live in `.dispatch-opencode/config.yaml` at the consumer-repo root.

```yaml
# .dispatch-opencode/config.yaml — example
default_model: ollama-cloud/glm-5.1
default_agent: build
default_timeout_sec: 600
worktree_root: .worktrees
templates_dir: skills/dispatch-opencode/templates
```

## Dispatch kinds

| Kind | Status | Use for |
|------|--------|---------|
| `single-file-fix` | **available** | One agent edits one file from a focused prompt. Required: `--target-file`. |
| `headless-spike` | **available** | Read-only investigation; agent writes a report file but does not edit source. Required: `--report-path`. Defaults to `--agent explore` (opencode's read-only built-in). |

Add a kind by:

1. Drop a `<kind>.sh.j2` in `templates/cli/`.
2. Add a row to the table above.
3. Add an example invocation to `references/examples.md`.

## What this skill does NOT do

- Run inside an editor as an ACP agent. Editor flows should call `opencode acp` directly.
- Expose opencode via MCP. opencode is an MCP client only.
- Manage opencode authentication. Run `opencode auth login` separately.
- Provision worktrees. The operator (or another skill) creates the worktree before dispatch.
- Coordinate between parallel agents beyond per-task isolation and shared `.subagents/` directory.

## References

- ADR-001: async `.subagents/` lock-watch as primary dispatch mode.
- Trove: `async-subagent-dispatch@5ca7b44` — async dispatch patterns, industry comparison, context packet standards.
- Trove: `opencode-runtime-integration@d9bad44` — failure-mode catalogue, session-in-session env-var leak (issue #24747).
- SPIKE-001: `--attach` session visibility on serve daemon.
- Examples: `references/examples.md`.
