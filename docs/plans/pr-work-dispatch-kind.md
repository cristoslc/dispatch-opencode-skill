# Plan: PR-Work Dispatch Kind

## Problem

The dispatch-opencode skill has `single-file-fix` and `headless-spike` kinds, but neither supports the sashay flow:

1. Branch + worktree creation
2. Draft PR with plan as body
3. Subagent dispatched into the worktree, using the PR as chronicle

Currently the operator must `cd .worktrees/<branch>` and start a session manually. This plan adds a `pr-work` kind that automates the handoff.

## Changes

### 1. New template: `templates/cli/pr-work.sh.j2`

A Jinja2 shell template that:

- Pushes the branch to remote (`git push origin HEAD:<branch>`)
- Creates a draft PR via `gh pr create --draft` with the prompt/plan as body
- Runs `opencode run` in the worktree directory
- Passes the PR URL as `$PR_URL` in the subagent's environment
- On exit, writes `FINAL_OUTPUT.md` with PR URL and exit code
- Cleans up .lock on exit

Uses the same serve vs local detection as `single-file-fix`.

### 2. New variables in `dispatch.sh`

- Add `--pr-title` flag
- Add `pr_work` case to the kind switch, rendering `pr-work.sh.j2` with template variables:
  - All existing: `task_id`, `generated_at`, `cwd`, `task_dir`, `model`, `agent`
  - New: `branch` (from `$WORKTREE_BRANCH`), `pr_title`
- `pr_title` defaults to task ID if not provided

### 3. Plan schema addition

```yaml
tasks:
  - id: implement-feature
    kind: pr-work
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/plan.md
    worktree: feat-123-branch      # required for pr-work
    pr_title: "Feat: implement feature X"  # optional, defaults to task id
```

### 4. Update `run-plan.sh`

- Parse `pr_title` from plan YAML and pass to `dispatch.sh`

### 5. Update `subagent-cleanup.sh`

No change needed — `git worktree remove` is local only. Remote branch and PR survive cleanup. Document this.

### 6. Update `SKILL.md`

- Add `pr-work` to dispatch kinds table
- Add plan schema example showing `pr_title` field
- Document what changes (worktree, PR body, chronicle pattern)

### 7. Update misc docs

- `templates/README.md`: add `pr-work` to template table
- `references/examples.md`: add `pr-work` invocation example

### 8. Tests

- New test `test_pr_work_flow.sh` covering create+dispatch
- Verify PR creation is skipped in test mode (dry-run flag)
- Parallel: add dry-run support to existing `test_uat_all_workflows.sh`

## Subagent prompt pattern

The start script sets `$PR_URL`. The prompt for the subagent should include:

```
You are working in a PR-tracked worktree at $PWD.
The draft PR URL is $PR_URL.
Use the PR as your chronicle:
1. Commit and push your changes regularly
2. Add a PR comment for each significant checkpoint
3. When done, ensure all tests pass and the PR is ready for review
```

## Completion and cleanup

- Subagent removes .lock when done
- Orchestrator reads FINAL_OUTPUT.md (includes PR URL)
- Orchestrator can optionally `gh pr ready` to mark ready for review
- `subagent-cleanup.sh` removes worktree, remote branch + PR survive
- Operator reviews the PR which has full chronicle in comments/commits

## Future

This is the worktree path. The dispatch kind design is agnostic to the execution target — a future sandbox or compute node variant would use a different template but the same plan schema and orchestration.

## Files touched

```
skills/dispatch-opencode/
  templates/cli/pr-work.sh.j2         [NEW]
  scripts/dispatch.sh                 [MODIFY: add pr-work case + --pr-title flag]
  scripts/run-plan.sh                 [MODIFY: parse pr_title from plan YAML]
  SKILL.md                            [MODIFY: add pr-work kind]
  templates/README.md                 [MODIFY: add pr-work row]
  references/examples.md              [MODIFY: add pr-work example]
  tests/test_pr_work_flow.sh          [NEW]
```