# Tech Stack

## Language and toolchain

- **Shell (bash).** All scripts are bash (`#!/usr/bin/env bash`). No Python runtime scripts — Python 3 is used only for template rendering and YAML parsing (invoked inline via `python3 -c`).
- **Python 3.11+.** Required for PyYAML (plan parsing) and Jinja2-style template variable substitution. Not a runtime dependency of the dispatch itself — only called during setup.
- **opencode CLI.** The dispatch target. Each subagent runs `opencode run` with model, agent, and prompt flags. See [opencode.ai](https://opencode.ai).

## Infrastructure

- **Git.** Repository and worktree management. Every dispatch requires a git work tree. Worktree isolation uses `git worktree add`.
- **File-based signaling.** No HTTP, no JSON-RPC, no sockets. `.lock` files for liveness, `FINAL_OUTPUT.md` for results, `events.jsonl` for audit.

## Test and CI

- **bash tests.** Integration tests under `tests/`. Run via `bash tests/<test>.sh`. Each test creates a temp git repo, dispatches, and verifies artifacts.
- **pre-commit.** Git hooks via `.pre-commit-config.yaml`. Includes gitleaks for secret detection.

## Toolchain dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| bash | yes | All scripts |
| git | yes | Work tree verification, worktree management |
| python3 | yes | Template rendering, YAML/JSON parsing |
| PyYAML | yes | Plan file parsing in `orchestrate.sh` |
| opencode | yes | Subagent execution (`opencode run`) |
| jq | recommended | `validate-run.sh` event stream parsing |
| uv | optional | Python dependency management if extending |

## Detail

- `docs/tech-stack/` — version pinning, upgrade notes, dependency rationale