# dispatch-opencode

A skill that lets agentic CLIs — Claude Code, Codex, and others —
dispatch subagent tasks through [opencode](https://opencode.ai) using
an async `.subagents/` lock-watch protocol.

## Why

Built-in subagent systems run one task at a time or are locked to a
single host runtime. Routing through opencode unlocks:

- **Broader model choice.** Dispatch tasks to any model opencode
  supports — mixing providers per subagent.
- **1-to-N parallelize.** Run N independent tasks with per-task
  worktree isolation.
- **Live attach.** Each subagent runs in an opencode session you can
  attach to from another terminal.
- **Auditable artifacts.** Every dispatch writes its prompt, event
  stream, and output to `.subagents/<task-id>/` for replay or audit.
- **Host-agnostic.** The dispatch target is always `opencode run`. No
  per-host adapter needed.

## How it works

The orchestrator (AI agent) writes a plan YAML, calls `run-plan.sh`,
and parses the structured JSON output. The script validates the plan,
prepares worktrees, dispatches each task, and returns lockfile paths
and PIDs. The orchestrator polls lockfiles on its own interval — when
a lockfile disappears, the subagent is done.

```
Agent ──► run-plan.sh ──► dispatch.sh ──► opencode run
  ▲                                       (background)
  │                                            │
  └──── poll .lock ──── .subagents/<id>/ ◄─────┘
```

## Quick example

```sh
# Write a plan
cat > plan.yaml <<'YAML'
tasks:
  - id: fix-auth
    kind: single-file-fix
    model: ollama-cloud/glm-5.1
    agent: build
    prompt: prompts/fix-auth.md
    target: src/auth.py
    worktree: fix-auth-branch
YAML

# Dispatch
result=$(bash skills/dispatch-opencode/scripts/run-plan.sh --plan plan.yaml)

# Poll lockfile, read FINAL_OUTPUT.md, then clean up
bash skills/dispatch-opencode/scripts/subagent-cleanup.sh --task-id fix-auth --root "$(git rev-parse --show-toplevel)"
```

## Install

1. Copy (or symlink) `skills/dispatch-opencode/` into your project's
   skill directory:
   - Claude Code: `.claude/skills/dispatch-opencode/`
   - Codex: `.agents/skills/dispatch-opencode/`
2. Ensure [opencode](https://opencode.ai), git, python3, and PyYAML
   are on PATH.

No build step. No per-host adapter. No configuration file.

## Dispatch kinds

| Kind | Use for |
|------|---------|
| `single-file-fix` | One agent edits one file from a focused prompt |
| `headless-spike` | Read-only investigation, agent writes a report file |

## Documentation

- `skills/dispatch-opencode/SKILL.md` — full design contract, dispatch
  flow, permission model
- `skills/dispatch-opencode/references/examples.md` — invocation
  examples per workflow

## License

MIT