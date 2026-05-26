---
source-id: failure-modes
title: "Known opencode stall and failure modes"
type: github-issues
fetched: 2026-04-25
verified: false
---

# Known failure modes

A dispatcher must handle these.

## Hang after tool calls (issue #17516)

<https://github.com/sst/opencode/issues/17516>. Affects v1.2.26+. `echo "..." | opencode run -m github-copilot/claude-sonnet-4.6` hangs after tool calls complete. Plain text queries exit cleanly. Open, labeled "core". **Mitigation:** wrap every invocation with `timeout`.

## Permission `ask` hang on serve+attach (issue #16367)

<https://github.com/sst/opencode/issues/16367>. Server doesn't relay `permission: ask` to the attached TUI in some configurations. **Mitigation:** set `permission: { "*": "allow" }` in config, or use `--dangerously-skip-permissions` on `run`.

## Silent exit on compaction overflow (issue #13946)

<https://github.com/anomalyco/opencode/issues/13946>. When auto-compaction fires and the compaction model itself overflows, the process exits with code 0 as if successful. **Mitigation:** `OPENCODE_DISABLE_AUTOCOMPACT=true` for headless work.

## Hang forever on API errors (issue #8203)

<https://github.com/anomalyco/opencode/issues/8203>. Provider 429 / 5xx errors don't always surface as `session.error`; the SSE loop never sees `idle`. **Mitigation:** external timeout. Maintainer (thdxr) on a related Kimi K2 thread: "the problem is openrouter is hanging and not giving us anything - we need to add a timeout here."

## Kimi K2 stops mid-task (issue #1329)

<https://github.com/sst/opencode/issues/1329>. Kimi K2 via OpenRouter silently stops; opencode sees no error. Workaround in thread: configure the endpoint as `@ai-sdk/openai-compatible` rather than the built-in `openrouter` provider:

> tools all worked when I set it to openai-compatible

Direct API (Moonshot, Groq) avoids the issue.

## Question tool hang (issue #10012)

<https://github.com/anomalyco/opencode/issues/10012>. If the model invokes the `question` tool in headless mode, no UI is available. The auto-deny rule in `run.ts` mitigates this, but `--dangerously-skip-permissions` is recommended belt-and-suspenders.

## Non-issue but worth documenting: `</think>` token leakage

Reasoning models (kimi-k2-thinking, glm-5.x, etc.) sometimes leak `</think>` tokens into stdout when generating long reasoning traces. The leak corrupts the visible log but does not affect file edits. (Observed in research-keeper INITIATIVE-003 design iteration, 2026-04-24.) **Mitigation:** post-process the captured log to strip `</think>` blocks.

## Frontmatter date drift

Both kimi-k2-thinking and glm-5.1 violate "do not modify frontmatter" instructions and bump `last-updated`. **Mitigation:** revert manually post-hoc, or guard with `git restore` on frontmatter sections.

## Word corruption on full rewrites

kimi-k2-thinking observed corrupting words during full-file rewrites: `efc2e8a → efx2e8a`, `REMAIN → REMIN`, `sidecar → sidecase`. glm-5.1 does not appear to have this pattern (likely because it favors targeted `Edit` operations). **Mitigation:** prefer agents that issue surgical edits over full Write rewrites; or post-validate via a known-good content hash.

## Cross-session interference (issue #4251)

<https://github.com/sst/opencode/issues/4251>. Running multiple sessions on different repos from one opencode instance caused cross-repo file modification. **Mitigation:** one server per CWD, or use git worktrees with `--dir` per session. No built-in file locking.

## Session-in-session env-var pollution (issue #24747)

<https://github.com/anomalyco/opencode/issues/24747>. When `opencode run` is invoked from within an opencode session, `OPENCODE_SERVER_PASSWORD` and `OPENCODE_SERVER_USERNAME` leak to the child. The child's in-process local server requires auth (the parent's credentials are set in the env), but the local-mode SDK client does not send auth headers — so session creation fails with "Session not found". **Mitigation:** unset `OPENCODE_SERVER_PASSWORD` and `OPENCODE_SERVER_USERNAME` before nested `opencode run`. Full analysis at `docs/troves/opencode-runtime-integration/sources/session-in-session/session-in-session.md`.

## Sources

- <https://github.com/sst/opencode/issues/17516>
- <https://github.com/sst/opencode/issues/16367>
- <https://github.com/anomalyco/opencode/issues/13946>
- <https://github.com/anomalyco/opencode/issues/8203>
- <https://github.com/sst/opencode/issues/1329>
- <https://github.com/anomalyco/opencode/issues/10012>
- <https://github.com/sst/opencode/issues/4251>
- <https://github.com/anomalyco/opencode/issues/24747>
- Field observation: `~/Documents/code/research-keeper/docs/swain-retro/2026-04-25-multi-round-design-iteration.md`
