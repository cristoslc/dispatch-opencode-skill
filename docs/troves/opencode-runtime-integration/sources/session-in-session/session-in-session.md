---
source-id: session-in-session
title: "Session-in-session: env var pollution causes 'Session not found' on nested opencode run"
type: github-issues+source-analysis
fetched: 2026-05-23
verified: false
notes: "Root-caused from env inspection and upstream issue analysis. Issue #24747 describes the same mechanism."
---

# Session-in-session: env var pollution

When `opencode run` executes as a child process of an opencode parent session, it inherits environment variables that the parent's in-process server set for its own authentication. The child then cannot create a new session, failing with `Session not found`.

## Root cause

The parent opencode process sets `OPENCODE_SERVER_PASSWORD` (and optionally `OPENCODE_SERVER_USERNAME`) in its environment for its internal in-process server. When it spawns a child `opencode run`, the child inherits these vars.

**How this breaks `opencode run`:**

1. The child starts an **in-process local server** (it does not connect to the parent).
2. The server's auth layer (`packages/opencode/src/server/auth.ts:20-21`) reads `OPENCODE_SERVER_PASSWORD` from the environment. If set, it requires HTTP Basic auth.
3. The local-mode SDK client (`packages/opencode/src/cli/cmd/run.ts:692-696`) creates a client with `createOpencodeClient(...)` — but does NOT pass auth headers in local mode.
4. The server rejects the unauthenticated session creation request.
5. The error surfaces as "Session not found".

This is upstream issue **#24747** (closed, assigned rekram1-node).

## Env vars that leak

Inspected from an active opencode session:

| Variable | Value | Effect on child |
|----------|-------|-----------------|
| `OPENCODE_SERVER_PASSWORD` | (set) | **Primary cause** — enables server auth; child's local server requires it; SDK doesn't send it |
| `OPENCODE_SERVER_USERNAME` | `opencode` | Default username for auth; harmless alone but paired with password |
| `OPENCODE_RUN_ID` | UUID | No known effect in source; candidate for future interference |
| `OPENCODE_PROCESS_ROLE` | `main` | No known effect in source |
| `OPENCODE_PID` | int | No known effect in source |
| `OPENCODE` | `1` | No known effect in source; feature request #1775 proposed using this for child detection |

The `OPENCODE_SERVER_PASSWORD` var is the only one that actively breaks nested `run`. The rest are harmless today but future versions could add interference.

## The inverse issue: `run --attach` auth gap (fixed)

Issue **#16096** was the inverse: `opencode run --attach` sending prompts to an external server also failed to pass auth headers. Fixed in **PR #16097** by adding `ServerAuth.headers({ password, username })` to the attach path (`run.ts:652-655`). The local-mode path (`run.ts:692-696`) was intentionally left without auth headers — it was designed for environments where `OPENCODE_SERVER_PASSWORD` is not set. The session-in-session bug is a gap in that design assumption.

## Fix (v1 — unset env vars)

The original mitigation was to unset the leaking vars before invoking the child:

```bash
OPENCODE_SERVER_PASSWORD= OPENCODE_SERVER_USERNAME= opencode run ...
```

Or more aggressively, clear all opencode vars:

```bash
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME opencode run ...
```

However, this approach means the child spawns its own in-process server (random port), making its session invisible to the operator.

## Fix (v2 — preferred: use --attach)

SPIKE-001 established a better approach: use `opencode run --attach` instead of the default local mode. The child connects to the parent's serve daemon as an HTTP client, never spawning its own in-process server. This avoids the env-var leak entirely — the parent's `OPENCODE_SERVER_PASSWORD` is used correctly by the child via the `--password` argument, not inherited as an environment conflict.

```bash
SERVER_URL="${OPENCODE_SERVER_URL:-http://localhost:4096}"
opencode run --attach "$SERVER_URL" --password "$OPENCODE_SERVER_PASSWORD" ...
```

Benefits over the unset approach:
- Child sessions are visible on the parent's serve daemon — operator can `opencode attach http://localhost:4096` to see all background sessions.
- No env var manipulation needed.
- The child's auth headers are sent explicitly as CLI arguments, not inherited from environment.

The `--attach` approach also avoids the earlier auth gap (issue #16096, fixed in PR #16097) because the `ServerAuth.headers()` call in the attach path (`run.ts:652-655`) correctly passes the password from the CLI argument.

## Alternative mitigations considered

- **`--fork` flag**: forks an existing session before continuing (requires `--continue` or `--session`). Not relevant — we want a fresh session, not a fork.
- **`/new` slash command**: in-TUI only, not available via `run`.
- **Wrapper script**: a `opencode` wrapper on PATH that unsets `OPENCODE_SERVER_PASSWORD` before exec'ing the real binary. Fragile (depends on PATH order) and hides the actual invocations from visibility.

## Sources

- Field observation: env inspection in an active opencode macOS session, 2026-05-23.
- opencode source: `packages/opencode/src/cli/cmd/run.ts` — local vs attach auth paths.
- opencode source: `packages/opencode/src/server/auth.ts` — `OPENCODE_SERVER_PASSWORD` reading.
- opencode source: `packages/core/src/flag/flag.ts` — env var declarations.
- Upstream issue #24747: `OPENCODE_SERVER_PASSWORD` env leak to child processes (closed).
- Upstream issue #16096: `run --attach` missing auth headers (fixed PR #16097).
- Feature request #1775: `OPENCODE=1` env var for child detection.
