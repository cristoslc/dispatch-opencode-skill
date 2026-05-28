# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.0] - 2026-05-28

### Added

- `run-plan.sh` — agent-facing entry point. Validates a plan YAML,
  prepares worktrees, dispatches tasks via dispatch.sh, returns
  structured JSON with lockfile paths and PIDs. Exits immediately —
  the orchestrator owns the poll loop.
- `subagent-cleanup.sh` — removes a completed task's .lock, worktree
  symlink, git worktree, and task directory. No force — should be
  clean after merge.
- `subagent-abandon.sh` — kills a failed task's PID (TERM then KILL),
  force-removes worktree and branch, deletes task directory.
- Design constraint 4: smart orchestrator, dumb subagents. The agent
  decides what is ready; subagents never coordinate.
- Worktree creation integrated into `dispatch.sh`. Worktrees live under
  `.subagents/<task-id>/worktree/` with a symlink at
  `.worktrees/<task-id>/`.
- Plan YAML schema for declaring tasks with id, kind, model, agent,
  prompt, target, and optional worktree branch.
- Hub files (PURPOSE.md, ARCHITECTURE.md, UBIQUITOUS-LANGUAGE.md,
  TECH-STACK.md, DEVELOPER-WORKFLOWS.md, USER-EXPERIENCE.md) and
  spoke directories under `docs/`.

### Changed

- `dispatch.sh` is now internal-only (not agent-facing). New interface:
  `--root`, `--cwd`, `--kind`, `--model`, `--agent`, `--prompt-file`,
  `--target`, `--task-id`, `--worktree`. Returns JSON on stdout. No
  poll loop. Spawn redirected to log files.
- `cleanup-stale.sh` enhanced with worktree scanning and `--abandon`
  flag. Scans `.worktrees/` for orphaned symlinks.
- SKILL.md updated to v2.0.0 — three agent workflows (single task,
  parallelize N, stale recovery), script inventory, plan schema,
  directory structure, structured output contract.
- Templates (`single-file-fix.sh.j2`, `headless-spike.sh.j2`) write
  artifacts to `$TASK_DIR` (project root's `.subagents/`) instead of
  cwd. No `cd` in templates.
- `test_lock_watch_cycle.sh`, `test_hello_world.sh`,
  `test_e2e_params.sh` updated for flag-based dispatch.sh interface.
- `test_dispatch_refactor.sh` — new test covering dispatch.sh JSON
  output, worktree creation/abandon, run-plan.sh dispatch and skip.
- UBIQUITOUS-LANGUAGE.md, ARCHITECTURE.md, USER-EXPERIENCE.md,
  README.md rewritten for v2 architecture.

### Removed

- `templates/runtimes/` directory and `references/runtimes.md`. No
  per-host adapter needed — the dispatch target is always
  `opencode run`.
- `worktree-prepare.sh`, `worktree-complete.sh`,
  `worktree-abandon.sh` — folded into task lifecycle
  (subagent-cleanup.sh, subagent-abandon.sh).
- `orchestrate.sh` — replaced by `run-plan.sh`.
- `collect-results.sh` — the orchestrator reads each FINAL_OUTPUT.md
  directly.
- `references/plan-schema.md` — merged into SKILL.md.
- Workflow 4 (result aggregation) removed from SKILL.md.

### Fixed

- dispatch.sh stdout now contains only JSON (all other output
  redirected to stderr).
- run-plan.sh stdout contains only JSON (log messages go to stderr).
- verify-cwd.sh output suppressed from dispatch.sh stdout.

## [1.0.0] - 2026-04-29

### Added

- Async `.subagents/` lock-watch protocol (ADR-001).
- `dispatch.sh` with positional-arg interface, poll loop, and spawn
  confirmation.
- `cleanup-stale.sh` for stale lock detection.
- `verify-cwd.sh` for fail-closed CWD verification.
- `validate-run.sh` for post-hoc event stream validation.
- `single-file-fix` and `headless-spike` dispatch kinds.
- Template rendering via python3 Jinja2-style substitution.
- --attach mode for session-in-session env-var leak avoidance.
- Troves: `async-subagent-dispatch`, `opencode-runtime-integration`.
- ADR-001: async lock-watch as primary dispatch mode.
- DESIGN-001: system contracts (superseded by PLAN-001).

### Changed

- Dropped ACP (Agent Client Protocol) and HTTP serve mode per ADR-001.
- Renamed from `opencode-dispatch` to `dispatch-opencode`.
- CLI `opencode run` as sole invocation transport.

### Fixed

- Auto-detect server URL for --attach vs --dir fallback.
- Unset OPENCODE_SERVER_PASSWORD to prevent session-in-session leak.
- Harden ACP session handling and Gemini arg parsing.
- Replace unsafe `unset` with explicit `--attach` flag approach.

[2.0.0]: https://github.com/cristoslc/dispatch-opencode-skill/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/cristoslc/dispatch-opencode-skill/releases/tag/v1.0.0