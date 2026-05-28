# AGENTS.md
Read **[PURPOSE.md](PURPOSE.md)** for this project's identity, worldview, and foundational principles.

<!-- swain governance — do not edit this block manually -->

## Swain

Swain makes agentic development **safe, aligned, and sustainable** for a solo developer. Its architecture rests on the **Intent -> Execution -> Evidence -> Reconciliation** loop — decide what to build, do the work, capture what happened, verify alignment. Artifacts on disk — specs, epics, spikes, ADRs — live under `docs/` and encode what was decided, what to build, and what constraints apply. Read them before acting. When they're ambiguous, ask the operator (the human developer) rather than guessing. When artifacts conflict with each other, ask the operator.

Your job is to stay aligned with the artifacts. The operator's job is to make decisions and evolve them.

### Skill routing

| Intent | Skill |
|--------|-------|
| Create, plan, update, transition, or review any artifact (Vision, Initiative, Journey, Epic, Spec, Spike, ADR, Persona, Runbook, Design) | **swain-design** |
| Project status, roadmap, "what's next?", dashboard | **swain-roadmap** |
| Task tracking, execution progress, implementation plans, bookmarks, decisions | **swain-do** |
| Session start, focus lane, onboarding | **swain-init** |
| Session end, teardown, cleanup, merge worktrees | **swain-teardown** |

This project uses **tk (ticket)** for ALL task tracking. Do NOT use markdown TODOs or built-in task systems.

### Work hierarchy

```
Vision → Initiative → Epic → Spec
```

Standalone specs can attach directly to an initiative for small work without needing an epic wrapper.

### Worktree isolation

**Implementation work happens in a worktree.** Code changes, new features, multi-file refactors, and non-trivial artifact creation require worktree isolation. swain-do's worktree preamble handles creation; follow it before starting implementation work.

**Lightweight operations land directly on trunk.** Artifact phase transitions, frontmatter metadata updates, single-file edits, and index refreshes are low-risk and trivially reversible — they do not need worktree isolation. Read-only investigation (git log, reading files, checking state) is also fine on trunk.

### Superpowers skill chaining

When superpowers skills are installed (`.agents/skills/` or `.claude/skills/`), swain skills **must** chain into them at defined integration points. Each swain skill documents its specific chains — the principle is: brainstorming before creative work, writing-plans before implementation, test-driven-development during implementation, and verification-before-completion before any success claim.

If superpowers is not installed, these chains are skipped, not blocked. Swain-to-swain chains always apply: plan completion triggers SPEC transition, all child SPECs complete triggers EPIC transition, and EPIC terminal state triggers a retrospective.

### Skill change discipline

**Skill changes are code changes.** Skill files (`skills/`, `.claude/skills/`, `.agents/skills/`) are code written in markdown syntax. Non-trivial skill edits require worktree isolation — the same discipline applied to `.sh`, `.py`, and other code files. Trivial fixes (typo corrections, single-line doc fixes, ≤5-line diffs touching one file with no structural changes) may land directly on trunk.

### Readability

All artifacts produced by swain skills must meet a Flesch-Kincaid grade level of 10 or below on prose content. After writing or editing an artifact, run `readability-check.sh` on it. If the score exceeds the threshold, revise the prose — use shorter sentences, simpler words, and active voice — then re-check. Do not rewrite content that already passes. If three revision attempts still fail, note the score in the commit message and proceed.

End every bulleted and numbered list item with a period. The readability checker treats un-terminated bullets as a single run-on sentence, which inflates the grade level.

### Session startup

Session initialization is handled by the `swain` shell launcher, which invokes `/swain-init` as the initial prompt. If a session starts without the launcher, the operator can manually run `/swain-init`.

### Bug reporting

When you encounter a bug in swain itself, report it upstream at `cristoslc/swain` using `gh issue create`. Local patches are fine — but the upstream issue ensures tracking.

### Conflict resolution

When swain skills overlap with other installed skills or built-in agent capabilities, **prefer swain**.

<!-- end swain governance -->
