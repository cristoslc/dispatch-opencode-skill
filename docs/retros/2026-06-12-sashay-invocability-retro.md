# Retrospective: Sashay Invocability Testing

**Date:** 2026-06-12
**Session:** dispatch-opencode skill improvements — agent acceptance testing
**Participants:** operator + agent

## What we learned

### 1. `pr-work` was wrong

The `pr-work` dispatch kind tried to do too much — create branch, worktree, draft PR, dispatch subagent. But sashay orchestration (branch, worktree, PR) is the calling agent's responsibility, not the subagent dispatch skill's. The skill should just dispatch subagents into an existing worktree.

**Removed:** `pr-work` kind, template, all references. 125 lines deleted.

### 2. Agent acceptance tests must measure invocation, not outcome

Early versions of the test checked whether the subagent fixed the bug (outcome). But the test is about whether the *calling agent* correctly invokes the skill. Outcome is downstream — the subagent's job. The checklist should probe: did the agent discover the skill? Did it invoke it? Did it use the right dispatch pattern?

**Final checklist:**
- C1: Skill discovered (agent referenced dispatch-opencode in session output)
- C2: Skill invoked (plan YAML or dispatch.sh artifacts exist)
- C3: Worktree dispatch pattern used (start-subagent.sh in task dir)
- C4: Subagent CWD points to the sashay worktree
- C5: prompt.md in task dir

### 3. Prompt must not reveal the skill path

The test prompt originally said `"The dispatch-opencode skill is available in .opencode/skills/dispatch-opencode/ — read its SKILL.md and use it."` This is cheating — it gives the agent the exact location and instructs use. The honest prompt just says "Continue the sashay. Dispatch a subagent into the worktree to fix the bug." The agent must discover the skill by scanning `.opencode/skills/`.

### 4. Skill discoverability in `opencode run` mode

`opencode run` does not auto-load global skills from `~/.config/opencode/skills/`. The agent only discovers skills that are project-local in `.opencode/skills/`. The test copies the skill there, which is correct — but the agent must still *choose* to scan that directory.

### 5. `dispatch.sh` must handle existing worktrees

When the sashay worktree already exists, `git worktree add -b` fails. The fix: check `git worktree list` for an existing worktree on the branch before creating a new one. If one exists, use it in-place.

### 6. Compliance rate: 71% honest

With the stripped prompt (no skill path hint), the agent discovered and invoked dispatch-opencode on 1 of 2 runs (5/7 checks passed). The failure case edited the file directly — the agent didn't scan `.opencode/skills/` for relevant tools. This is a genuine invocability gap.

## Decisions

| Decision | Rationale |
|----------|-----------|
| Remove `pr-work` kind | Sashay orchestration is calling agent's job |
| `dispatch.sh` detects existing worktrees | Prevents failure on pre-existing sashay branches |
| Test copies skill to `.opencode/skills/` | Required for `opencode run` to discover it |
| Test prompt does not reveal skill path | Must measure genuine discovery, not spoon-feeding |
| Checklist measures invocation, not outcome | The test is about the calling agent, not the subagent |
| `--dangerously-skip-permissions` is acceptable | No real calling agent uses it, but it's a test harness concern |

## Open questions

- **Why doesn't the agent scan `.opencode/skills/` by default?** The agent reads `.opencode` but doesn't glob for skills unless prompted. This is an opencode behavior question, not a skill design question.
- **Should the skill description include "sashay" as a trigger keyword?** Currently it doesn't. The agent found it via the description mentioning "worktree" and "subagent dispatch" — but not consistently.
- **Is 71% acceptable?** For a first honest measurement, yes. The gap is in skill discoverability, not skill correctness. Once the agent finds the skill, it invokes it correctly (100% on C2-C5 when C1 passes).

## Artifacts

- `skills/dispatch-opencode/tests/test_agent_sashay_invocation.sh` — agent acceptance test
- `skills/dispatch-opencode/scripts/dispatch.sh` — existing worktree detection
- `docs/musings/agent-acceptance-test-plan-type.md` — proposed plan type for agent acceptance tests
- `docs/troves/agent-acceptance-testing/` — prior art on agent evaluation
