# Watcher Root Path Bug

Date: 2026-08-12

## The observation

The watcher daemon (`skills/dispatch-opencode/scripts/watcher.sh`) computes
`PROJECT_ROOT` from its own install location, not from the project it is
watching.

The scripts live at `skills/dispatch-opencode/scripts/`. The daemon does:

```bash
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
```

`SCRIPT_DIR` is `.../skills/dispatch-opencode/scripts`. Two hops up lands at
`.../skills/`, not the repo root. The repo root is three hops up.

## Why it matters

The daemon uses `PROJECT_ROOT` to find `.subagents/`, the watch directory,
the PID file, and the log file. With the wrong root:

- `watcher.sh start` creates `.subagents/watch/` under `skills/`, not the
  project root. The agent writes plans to `<root>/.subagents/watch/`, so the
  daemon never sees them.
- `stop` and `status` look for the PID file in the wrong place.
- Dispatched subagents get the wrong `--root`, so their task directories,
  worktrees, and result summaries land in the wrong tree.

The bug defeats background dispatch entirely: plans are dropped in one
place, the watcher scans another.

## What the fix needs

The daemon must resolve the project root relative to the project it serves,
not relative to where the skill is installed. The skill ships in
`skills/dispatch-opencode/`, so the root is the repo root of the project
that consumes the skill.

This means walking up from the script directory past `dispatch-opencode/`
and `skills/` to the project root — three hops — or better, resolving the
root from a marker. A git root (`.git`) is the natural anchor: a project
root is where `.git/` lives, and `.subagents/` sits next to it.

But this is a shared skill. It may be symlinked into a consuming project
(`.agents/skills/` or `.claude/skills/`). Symlink resolution and the exact
install depth vary. The fix should be robust to that, not hardcode three
hops.

## Open questions

- Should the daemon anchor on `.git`, or should it require the caller to
  pass `--root` explicitly? The skill's own rule is "every dispatch takes
  an explicit absolute path; verification fails closed" — the daemon
  defaulting to a guessed root feels like it violates that rule.
- How does the daemon behave when invoked inside the skill's own repo vs.
  a consuming project? The two should resolve the same way.

This is step zero. The concrete fix should become a plan, then a sashay.
