# Two-call dispatch as primary path

## Problem

The SKILL.md describes workflows that bundle dispatch + polling into a single linear sequence. The watcher daemon (Workflow 4) was added to solve "background dispatch" but adds daemon lifecycle complexity. The scripts already support a cleaner two-call pattern: `run-plan.sh` returns immediately, `poll-subagent.sh` is called separately.

## Tasks

- [ ] Rewrite SKILL.md Workflow 1 (Single task) to show two-call pattern
- [ ] Rewrite SKILL.md Workflow 2 (Parallelize N tasks) to show two-call pattern
- [ ] Demote watcher daemon from Workflow 4 to a secondary/optional pattern
- [ ] Add `poll-all.sh` convenience script — polls all active tasks in a project root, returns summary JSON
- [ ] Update script inventory table in SKILL.md
- [ ] Update "When to use" section to emphasize two-call pattern
- [ ] Update "Agent workflows" section header structure

## Files to change

- `skills/dispatch-opencode/SKILL.md` — primary target
- `skills/dispatch-opencode/scripts/poll-all.sh` — new file
