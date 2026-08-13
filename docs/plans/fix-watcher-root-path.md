# Fix: watcher daemon project root path

Date: 2026-08-12

## Problem

`skills/dispatch-opencode/scripts/watcher.sh` derives `PROJECT_ROOT` from
its own install location, not from the project it serves:

```bash
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
```

`SCRIPT_DIR` is `.../skills/dispatch-opencode/scripts`. Two hops up lands
at `.../skills/`, not the repo root. The repo root is three hops up. As a
result:

- `watcher.sh start` creates `.subagents/watch/` under `skills/`, not the
  project root, so plans the agent drops at `<root>/.subagents/watch/` are
  never seen.
- `stop` and `status` read the PID file from the wrong location.
- Dispatched subagents get the wrong `--root`, so task directories,
  worktrees, and results land in the wrong tree.

The bug defeats background dispatch entirely.

## The fix

Require an explicit `--root` on `watcher.sh start`, matching the skill's
core design constraint ("every dispatch takes an explicit absolute path;
verification fails closed. No defaults, no inference").

- `watcher.sh start --root <project-root>` sets the project root.
- `stop` and `status` also require `--root`, since they must find the PID
  file and log in the same root.
- If `--root` is omitted, exit non-zero with a clear error. Never guess.

### Why `--root` and not auto-derivation

The skill is a shared skill. It ships in `skills/dispatch-opencode/` but is
consumed by other projects via symlink (`~/.config/opencode/skills/`,
`.agents/skills/`, `.claude/skills/`). Install depth and symlink layout
vary, so hardcoding hops or walking to a `.git` marker is fragile. The
operator knows the project root; an explicit flag is unambiguous and
matches every other script in the skill (`run-plan.sh`, `dispatch.sh`,
`poll-subagent.sh` all take `--root`).

## Changes

### `skills/dispatch-opencode/scripts/watcher.sh`

- Add `--root` to the `start` subcommand's flag loop (alongside
  `--watch-dir` and `--interval`).
- Add a `--root` argument to `stop` and `status` subcommands.
- Replace the three `PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"`
  lines with a `require_root()` helper that errors if `--root` is empty or
  does not exist.
- Update the usage comment and error text to document `--root`.

### `skills/dispatch-opencode/SKILL.md`

- Update the "Watcher daemon" section's `start`/`stop`/`status` examples
  to include `--root`.
- Update the "Workflow 4: Background dispatch" section step 1 to show
  `watcher.sh status --root <project-root>`.

### `docs/spec/Proposed/(SPEC-001)-Watcher-Daemon-Script/(SPEC-001)-Watcher-Daemon-Script.md`

- Update the `watcher.sh start`/`stop`/`status` usage lines (lines 34-36,
  68-70) to include `--root`, so the Proposed spec does not drift from the
  implemented interface.

### `docs/plans/fix-watcher-root-path.md`

- This plan. Update here as needed.

## Tests

Add a test at `skills/dispatch-opencode/tests/test_watcher_root.sh` that:

1. Runs `watcher.sh status --root <temp-root>` with no daemon running and
   asserts it prints `"status":"stopped"` and a valid JSON.
2. Runs `watcher.sh start --root <temp-root>` and asserts the PID file and
   watch dirs are created under `<temp-root>/.subagents/`, not under the
   script's own directory.
3. Runs `watcher.sh stop --root <temp-root>` and asserts the daemon stops
   and the PID file is removed.
4. Runs `watcher.sh status` (no `--root`) and asserts non-zero exit and an
   error message.

## Acceptance criteria

- `watcher.sh start --root <root>` writes `.subagents/watcher.pid`,
  `.subagents/watcher.log`, and the `watch/` tree under `<root>`, not under
  the script directory.
- `watcher.sh stop --root <root>` finds and stops the daemon.
- `watcher.sh status --root <root>` reports correct running state.
- Omitting `--root` fails loudly with a clear error, no guessing.
