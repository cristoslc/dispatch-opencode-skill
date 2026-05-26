---
name: dispatch-opencode
description: >
  Dispatch a subagent task through opencode (https://opencode.ai) instead of
  the host CLI's built-in subagent runtime. The skill drives opencode over
  ACP (Agent Client Protocol) on a fixed port, so the operator can attach
  to the live session for inspection or manual steering. Use when the
  operator wants broader model choice (open-weight via Ollama Cloud,
  OpenRouter, etc.), wants live attach, or needs auditable on-disk
  dispatch artifacts. TRIGGER when: the parent agent would otherwise
  spawn a built-in subagent and the operator has indicated opencode is
  the preferred backend, or when the task benefits from a model the host
  doesn't natively support, or when parallel fanout with per-task
  isolation is required.
license: MIT
compatibility: Requires opencode CLI (https://opencode.ai), git, Python 3.11+, and uv
metadata:
  version: "0.3.0"
  status: draft
  author: cristoslc
---

# dispatch-opencode

Routes subagent dispatch through opencode using **ACP (Agent Client
Protocol) over a fixed HTTP port**. The skill is the ACP client; the
operator can `opencode attach http://<host>:<port>` from another terminal
to see the live session and steer it.

This is the primary mode. CLI `opencode run` and HTTP `opencode serve`
remain as alternates for the cases ACP doesn't fit (see "Alternate
modes" below).

ACP is the right default because it solves four problems at once that
the CLI/HTTP modes only solved partially:

- **Native permission relay.** No `--dangerously-skip-permissions`, no
  wildcard `permission: { '*': 'allow' }` config hack. The host (or
  the skill on its behalf) approves or denies each tool call as
  opencode asks.
- **Zero shell-injection surface.** Prompts and arguments are JSON-RPC
  payloads, not shell strings. No quoting, no template-injection class.
- **Standardized session lifecycle.** `initialize`, `newSession`,
  `prompt`, `setSessionModel`, idle detection — all wire-defined.
- **Live attach via the same internal HTTP server** that ACP boots.
  When the port is fixed, `opencode attach <url>` reaches it like any
  other opencode server.

## When to use

- The operator wants an open-weight model (Kimi K2, GLM, Qwen, Llama)
  the host doesn't natively support.
- The operator wants to attach to a running subagent for live
  inspection or manual steering.
- The task fans out across N independent files or repos and needs
  per-task isolation (worktree-per-task).
- The operator wants the dispatch artifact (prompt parts, files,
  model, agent, cwd) on disk for replay or audit.

If none apply, prefer the host CLI's built-in subagent runtime — this
skill adds a process boundary and a protocol layer.

## When NOT to use

- One-shot prompts where cold-start cost dominates and live attach is
  not needed. Fall back to alternate-mode CLI `opencode run`.
- The host runtime forbids spawning long-lived subprocesses. Fall back
  to alternate-mode CLI `run` per task.

## Three design constraints (non-negotiable)

These hold across all modes.

1. **The skill owns the working directory.** Host runtimes differ in
   their ability to shift CWD mid-session — Claude Code can; Codex and
   Gemini are not assumed to. Every dispatch takes an explicit absolute
   path; the skill verifies the path exists, is a git work tree, and
   matches an expected branch or worktree label. **Verification fails
   closed** — no defaults, no inference. The verified path is passed to
   ACP `newSession` (or `--dir` in CLI mode).

2. **Handoffs are on-disk artifacts.** Every dispatch writes the
   request payload to disk under `.dispatch-opencode/<task-id>/` before
   sending. In ACP mode the artifact is the rendered `prompt` request
   body (`prompt.json`); in CLI mode it is a `dispatch.sh`. Either way
   the task directory is the source of truth for replay and audit.

3. **One template per dispatch *kind*.** Templates are typed by what
   the dispatch is *for* (e.g., `single-file-fix`,
   `parallel-review-fanout`, `headless-spike`), not parameterized into
   a single megatemplate. ACP and CLI mode each have their own per-kind
   template family.

## Required arguments

A host runtime invokes the skill with these named arguments.

| Flag | Required | Type | Description |
|------|----------|------|-------------|
| `--kind` | yes | enum | One of the kinds in the table below. |
| `--cwd` | yes | absolute path | Working directory; must pass `verify-cwd.sh`. |
| `--branch` | no | string | Expected branch name; verified against `git branch --show-current`. |
| `--worktree` | no | label | Expected worktree label; requires `--worktree-root`. |
| `--worktree-root` | conditional | absolute path | Worktree-root prefix; required when `--worktree` is set. |
| `--model` | yes | `provider/model` | opencode model string (e.g. `ollama-cloud/glm-5.1`). |
| `--agent` | yes | string | opencode agent name (`build`, `general`, `explore`, or a project agent). |
| `--target-file` | conditional | path | Required by `single-file-fix`. Path inside `--cwd`. |
| `--prompt-file` | yes | path | Path to a markdown prompt file; rendered into the task dir as `prompt.md`. |
| `--timeout` | no | seconds | Per-dispatch timeout. Defaults to `default_timeout_sec` in `config.yaml`. |
| `--mode` | no | enum | `acp` (default), `cli`, or `http`. |
| `--extra-env` | no | `K=V` (repeatable) | Extra environment for the rendered script. Keys must match `^[A-Za-z_][A-Za-z0-9_]*$`; values are shell-quoted by the renderer. CLI mode only. |

Per-kind required arguments are listed alongside each kind below.

## Dispatch flow (ACP mode, primary)

1. **Parse intent** — kind, model, agent, target file(s), prompt body,
   CWD.
2. **Resolve CWD** — absolute path, must be a git work tree.
3. **Verify CWD** — `scripts/verify-cwd.sh <path> [--branch <name>]
   [--worktree <label> --worktree-root <absolute-root>]`. Exit non-zero
   aborts the dispatch.
4. **Allocate task ID** — `<UTC-timestamp>-<short-hash-of-prompt>`.
   Create `.dispatch-opencode/<task-id>/`.
5. **Render prompt parts** — pick the template by kind from
   `templates/acp/<kind>.prompt.j2`. Render prompt text plus the file
   part list into `.dispatch-opencode/<task-id>/prompt.json` (the ACP
   `prompt` request body). Also write `prompt.md` (the raw prompt
   text) and `parts.json` (the file/text parts that the prompt
   references) for human inspection.
6. **Ensure ACP backend** — connect to or spawn `opencode acp --port
   <fixed-port>` (port read from `config.yaml`). Confirm the embedded
   HTTP server is reachable at `http://<host>:<port>`. Log the URL —
   the operator needs it to attach.
7. **Initialize + newSession** — send ACP `initialize`, then
   `newSession({ cwd: <verified-path>, mcpServers: [], model: <model>,
   agent: <agent> })`. Capture `sessionId`.
8. **Pre-flight log** — print `task-id`, verified CWD, model, agent,
   ACP server URL, session ID, attach command:

   ```
   opencode attach http://127.0.0.1:4096 --session <sessionId>
   ```

9. **Send prompt** — POST the rendered `prompt.json` as the ACP
   `prompt` request. Stream the response events to
   `.dispatch-opencode/<task-id>/events.jsonl` and any text deltas to
   `stdout.log`.
10. **Handle permission asks** — when ACP delivers a `permission.ask`
    request, the skill consults the per-kind allowlist (see "Permission
    model" below) and responds `allow_once` / `allow_always` /
    `reject`. Each decision is logged with reason and rule reference.
11. **Wait for idle** — return when the session reaches the ACP idle
    state, or when `--timeout` elapses.
12. **Post-run validate** — `scripts/validate-run.sh <task-dir>`.
    Auto-detects ACP vs CLI mode from the events.jsonl shape. ACP
    mode checks: the last JSON-RPC response carries
    `result.stopReason == "end_turn"`; no error responses; surfaces
    any `tool_call_update` notifications with `status == "failed"` as
    warnings; strips `</think>` blocks from `stdout.log` and
    `events.jsonl` (reasoning-model leakage). CLI mode checks: last
    `session.status` event has `properties.status.type == "idle"`.
13. **Return result** — exit code, task-dir path, session ID,
    attach URL. The host parent treats this as the subagent's output.

## Permission model

ACP delivers each tool-call permission ask to the client. The skill
ships a per-kind allowlist; defaults are conservative.

| Kind | Read | Write | Bash | Task / sub-dispatch |
|------|------|-------|------|---------------------|
| `single-file-fix` | repo | only `--target-file` | deny | deny |
| `parallel-review-fanout` | repo | only each child's own `--target-file` (one per child) | deny | deny |
| `headless-spike` | repo | only `--report-path` | readonly allowlist (see "Bash gating" note) | deny |

Outside the allowlist, the skill rejects. The operator can
override per-task with `--permission-override <rule>` (logged) or via
the attached TUI when answering the permission prompt out-of-band.

**Bash gating: HTTP-probe workaround.** opencode 1.14.x sends
`rawInput: {}` in `session/request_permission` for the bash tool — the
actual command only lands later, in a `tool_call_update` notification
after the permission decision is made. That's not enough to gate by
command at decision time on its own, but the command is reachable a
different way: while the permission ask is pending, `GET
/session/<id>/message` on the embedded HTTP server returns the
matching tool-call part with `state.input.command` already populated.

The dispatcher uses this. When the `bash_readonly` action sees an
empty `rawInput.command`, it issues an HTTP probe to opencode's own
server (the same one the operator can `opencode attach` to), walks
the message list to find the tool-call part by `callID`, extracts
`state.input.command`, and applies the regex on the real command.
This restores the advertised behaviour: `git status` is allowed,
`rm -f …` is rejected, and so on. Verified in the adversarial test
at `tests/test_headless_spike_safety.sh`.

**Layering with `opencode.json` (complementary, not required).** The
HTTP-probe workaround is the dispatcher's primary mechanism. As a
defense-in-depth layer, the consumer project can also set
per-command rules in `opencode.json` so safe commands resolve inside
opencode without an ACP ask at all:

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

Both layers reach the same decisions; the layered config is faster
(no ACP round-trip) and survives any future change to opencode's
permission payload shape.

The adversarial test at `tests/test_headless_spike_safety.sh`
exercises the reject paths (edit on a non-target file, bash) and
verifies source files and the marker file are not modified across
runs.

## Default failure-mode mitigations

Baked in by the skill's ACP client and rendered artifacts.

- `--timeout <SLA>` enforced by the ACP client. Stalls do not block
  forever.
- `OPENCODE_DISABLE_AUTOCOMPACT=true` set in the spawned `opencode acp`
  process — avoids silent exit on compaction overflow (issue #13946).
- `OPENCODE_DISABLE_AUTOUPDATE=true` set in the same env — keeps
  unattended runs deterministic.
- `OPENCODE_SERVER_PASSWORD` required (refuse to start ACP backend
  without one). The fixed-port server is otherwise unauthenticated.
- **CLI-mode templates attach to the parent's serve daemon** using
  `--attach "$SERVER_URL" --password "$OPENCODE_SERVER_PASSWORD"` (SPIKE-001).
  The child is an HTTP client of the parent server, never spawning its own
  in-process server — avoids the session-in-session env-var leak (issue #24747).
- Per-kind permission allowlist (see above). No wildcard allow, no
  `--dangerously-skip-permissions`.
- Post-run `</think>` strip on `stdout.log` and `events.jsonl`
  (reasoning-model leakage).
- Frontmatter diff guard on protected files; auto-revert on drift
  (planned, not yet implemented).
- For Kimi K2 specifically: route via `@ai-sdk/openai-compatible`
  rather than the built-in `openrouter` provider (issue #1329).

## Configuration

Defaults live in `.dispatch-opencode/config.yaml` at the consumer-repo
root.

```yaml
# .dispatch-opencode/config.yaml — example
mode: acp                          # acp | cli | http
acp:
  port: 4096                       # fixed; required for live attach
  hostname: 127.0.0.1              # 0.0.0.0 only if you understand mDNS / firewalling
  spawn: true                      # true → skill spawns `opencode acp`; false → expects a running one
  password_env: OPENCODE_SERVER_PASSWORD   # must be set; the skill refuses to start without it
default_model: ollama-cloud/glm-5.1
default_agent: build
default_timeout_sec: 600
worktree_root: .worktrees
protected_frontmatter_keys:
  - last-updated
templates_dir: skills/dispatch-opencode/templates   # adjust if installed elsewhere, e.g. .agents/skills/dispatch-opencode/templates
```

The fixed `acp.port` is what makes ACP mode attachable. Changing it
later breaks any operator-facing attach commands the skill has logged.

## Dispatch kinds

Each available kind has matching templates under
`templates/acp/<kind>.prompt.j2` (and, for the alternate CLI mode,
`templates/cli/<kind>.sh.j2`).

| Kind | Status | Use for |
|------|--------|---------|
| `single-file-fix` | **available** (ACP + CLI + HTTP) | One agent edits one file from a focused prompt. Required: `--target-file`. |
| `parallel-review-fanout` | **available** (ACP) | N agents, N files, shared decisions doc. Each child gets its own opencode acp on a unique port (`acp.port + i`). Field-validated against research-keeper INITIATIVE-003 (4 agents, 9 rounds, 0 merge conflicts). Required: `--target-files` (comma-separated) and `--shared-decisions` (path); optional `--parallel <N>` to throttle concurrency. ACP-only — orchestration depends on per-child sessions. |
| `headless-spike` | **available** (ACP) | Read-only investigation; agent writes a report file but does not edit source. Required: `--report-path`. Defaults to `--agent explore` (opencode's read-only built-in). The kind's allowlist permits `read`, `search`, `edit`-only-on-`--report-path`, and a small bash readonly set (`git status`, `git diff`, `git log`, `git show`, `git ls-files`, `git rev-parse`, `ls`, `cat`, `head`, `tail`, `wc`, `file`); everything else is rejected. |

Selecting a kind whose template is missing for the chosen mode aborts
the dispatch with a clear error.

Add a kind by:

1. Drop a `<kind>.prompt.j2` in `templates/acp/`.
2. Drop a `<kind>.sh.j2` in `templates/cli/` (optional).
3. Add a permission-allowlist row to "Permission model".
4. Add a row to the table above.
5. Add an example invocation to `references/examples.md`.

Don't subclass templates or add j2 inheritance for v1. Copy-paste
between templates beats premature abstraction.

## Composition

The composition axes from the v0.2 design are partially landed:

- **Runtime axis** — per-host adapters under
  `templates/runtimes/<host>/`. `claude-code/oc-dispatch.md` is
  validated end-to-end against this repo; `codex/`, `gemini/`, and
  `cursor/` ship illustrative snippets that have NOT been run against
  their respective installs. See `references/runtimes.md` for the
  status matrix.
- **Agent-type axis** — covered by the per-kind template layer
  (`templates/<mode>/<kind>.<ext>`).
- **Model axis** — not yet implemented. Per-provider overrides
  (timeout, retry, structured-output shape, prompt-shape adjustments)
  would live under `templates/models/<provider>/<model>.j2` if a
  concrete need surfaces. Don't pre-build it.

## Alternate modes

### CLI `run` per task — `--mode cli` (available)

Best for fire-and-forget where live attach is not needed. The
dispatcher renders `templates/cli/<kind>.sh.j2` to `dispatch.sh` in
the task dir, then exec's it. The script wraps `opencode run --format
json` in `timeout` (or `gtimeout`; falls back to no timeout with a
warning when neither is on PATH) and writes `events.jsonl`,
`stdout.log`, `stderr.log`. The operator can replay an exact run with
`bash <task-dir>/dispatch.sh`.

CLI mode requires `--dangerously-skip-permissions`. In ACP mode that
flag is forbidden because ACP relays permission asks to the client
instead.

CLI mode does not support `parallel-review-fanout` (orchestration is
ACP-only) — use `--mode acp` for that kind.

### HTTP `serve` + REST — `--mode http` (available, with caveat)

Best for cases where the operator wants a long-lived warm dispatcher
that's also reachable from `opencode attach` and other HTTP clients.
The skill spawns `opencode serve --port <fixed>` per task, sends the
prompt via `POST /session/<id>/message` (a single text part — the
agent uses its read tool to fetch the target file), and consumes the
SSE event stream from `/event` until the session reaches
`session.status: idle`.

**Permission-relay caveat (issue #16367).** HTTP mode does not get
native permission-ask relay. Tools that are configured to ask for
permission will hang. The dispatcher logs a warning at entry. To use
HTTP mode, configure permissive rules in your project's
`opencode.json` (e.g., `permission: { "*": "allow" }`) or accept the
risk.

If you need both live attach AND permission-relay safety, use ACP
mode — its embedded HTTP server is also `opencode attach`-reachable
when the port is fixed.

## What this skill does NOT do

- Run inside an editor as the ACP agent for that editor (Zed,
  JetBrains). Editor flows should call `opencode acp` directly via
  the editor's agent-server config — that is opencode's primary ACP
  use case and this skill is the wrong wrapper for it.
- Expose opencode via MCP. opencode is an MCP client only.
- Manage opencode authentication. Run `opencode auth login`
  separately.
- Provision worktrees. The operator (or another skill — `swain-do`'s
  worktree preamble in swain projects) creates the worktree before
  dispatch.
- Coordinate between parallel agents beyond per-task isolation. If
  agents need to converge on cross-cutting decisions, use a
  shared-decisions doc as a separate artifact and pass it into each
  agent's prompt.

## References

- Trove: `opencode-runtime-integration@d9bad44` —
  `docs/troves/opencode-runtime-integration/synthesis.md` and source
  files (8 sources). Failure-mode catalogue at
  `docs/troves/opencode-runtime-integration/sources/failure-modes/failure-modes.md`.
- ACP source: `packages/opencode/src/cli/cmd/acp.ts` and
  `packages/opencode/src/acp/agent.ts` in github.com/sst/opencode.
- ACP attachability check (this design's foundation): the embedded
  server uses the same `withNetworkOptions` / `Server.listen` path as
  `opencode serve`. Defaults are port `0` (random) and hostname
  `127.0.0.1`; pass an explicit `--port` to make the URL reachable
  from `opencode attach`.
- Field evidence: `~/Documents/code/research-keeper/docs/swain-retro/2026-04-25-multi-round-design-iteration.md`.
- Examples: `references/examples.md`.
