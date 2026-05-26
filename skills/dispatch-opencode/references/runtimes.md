# Runtime adapters

Per-host integration notes for invoking `opencode run` via the CLI template. The skill is **runtime-neutral** — the template (`templates/cli/single-file-fix.sh.j2`) drives `opencode run` directly. Adapters are thin shims: a slash command, a rules entry, or a config snippet that sets up the `.subagents/` directory and passes the right args.

## Status matrix

| Host | Tested | Adapter |
|------|--------|---------|
| Claude Code | yes (this repo) | `templates/runtimes/claude-code/oc-dispatch.md` — copy to `.claude/commands/oc-dispatch.md` |

Adapters marked "no" have been removed — the async `.subagents/` protocol is runtime-neutral. Any host with a "run a shell command" tool can invoke `opencode run` directly using the CLI template.

## The dispatch contract

The skill writes a `start-subagent.sh` into `.subagents/<task-id>/` which invokes:

```sh
opencode run --attach "$OPENCODE_SERVER_URL" --password "$OPENCODE_SERVER_PASSWORD" --format json ...
```

When `OPENCODE_SERVER_URL` is unset (e.g., Claude Code as parent), it falls back to local `--dir` mode.

## When to write a custom adapter

Skip the templates here and write your own when:

- The host requires a non-shell entry point (e.g., MCP tool, browser extension protocol).
- The operator wants a richer UX than a single command (e.g., a picker over kinds).
- Your install differs enough from the templates that copying them would mislead.
