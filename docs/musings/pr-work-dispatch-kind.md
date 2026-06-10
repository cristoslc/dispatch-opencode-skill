# PR-Work Dispatch Kind

## What I'm trying to do

Make the dispatch-opencode skill support a "create PR, hand off work to a subagent in a worktree, subagent uses PR as chronicle" flow. The user calls this the "sashay":

1. Branch + worktree creation
2. Draft PR with the plan as the body
3. Subagent dispatched into the worktree, using the PR as its working chronicle

## Why this matters now

Operators (me) are reaching a stage where the agent on `:main` can plan and scaffold, but then I have to manually `cd .worktrees/<branch>` and start a new session. The gap is: the orchestrator agent can't hand off to a subagent that works inside a PR-tracked context. If I can dispatch an agent that treats the PR as its living document — commits updates as comments, pushes commits, maybe even marks the PR ready — I eliminate the manual handoff.

## What already exists

The dispatch skill has two kinds: `single-file-fix` and `headless-spike`. Both dispatch `opencode run` in `--dir` (or `--attach`) mode. Both support optional `worktree` field in the plan YAML. Both write artifacts to `.subagents/<id>/` and the orchestrator polls and merges.

## What's different about PR-work

The `single-file-fix` kind is designed for the orchestrator to own the lifecycle: it dispatches, polls, reads FINAL_OUTPUT.md, then the orchestrator commits and merges. The subagent is "dumb" — it edits files, reports, done.

PR-work inverts this: the subagent owns the commit/push cycle and uses the PR as its chronicle. The orchestrator's job is just to:
1. Create the branch + worktree
2. Create the draft PR with the plan as the body
3. Dispatch the subagent into the worktree
4. Optionally poll for completion, but the subagent is semi-autonomous

The subagent should:
- Work in the worktree directory
- Commit and push iteratively as it makes progress
- Update the PR body or add comments as chronicle entries
- On completion, either mark the PR ready or signal done

## Design questions

### Does the subagent run in --attach mode or --dir mode?

- `--attach` mode means it connects to a running `opencode serve` daemon. The subagent is visible to the operator who can attach from another terminal. This is the richer experience.
- `--dir` mode means it runs headless, detached. The subagent has no interactive session. This is more self-contained but harder to debug.
- The user's description suggests the subagent should be backgrounded ("handoff to agent working off of PR"), which means it's fine either way. I'd lean toward `--attach` when a serve daemon is running, `--dir` as fallback — same pattern as existing kinds.

### PR body management

The PR body starts as the plan. The subagent updates it as a chronicle — appending sections like "Completed: X", "In progress: Y", "Blocked: Z". This requires `gh pr edit --body` which replaces the entire body, so the subagent needs to:
1. Read current PR body
2. Append new chronicle entry
3. Write it back

Or alternatively, use PR comments as the chronicle stream. Comments are append-only, no read-modify-write race. Each significant checkpoint gets a new comment. The PR body stays as the plan/summary.

### What does completion look like?

- Subagent runs its task. When done, it removes the `.lock` file (or writes a specific marker).
- Optionally marks the PR as "Ready for Review" via `gh pr ready`.
- The orchestrator (or operator) then reviews the PR, which has the full chronicle in comments and commits.

### What about the worktree lifecycle?

After dispatch, the worktree is under `.subagents/<id>/worktree/`. The subagent pushes to the branch. The orchestrator doesn't merge — that's the operator's review step. `subagent-cleanup.sh` would remove the worktree but NOT delete the remote branch (since the PR is still open). That means cleanup is different from single-file-fix.

### Templates needed

A new `pr-work.sh.j2` template. It needs:
- Variables for branch name, model, prompt, target (maybe not target, since it's a whole worktree), agent type
- Logic to `gh pr create --draft` with the plan as body
- The subagent prompt should include instructions about PR chronicle usage

### Relationship to the operator's flow

The operator said:
> I often have an agent on :main/:trunk create a worktree and PR for a chunk of work, but I'm still manually switching to the worktree to kick off a new session.

This means the operator's current flow is:
1. Agent on trunk plans and scaffolds
2. Creates a branch and pushes it
3. Opens a draft PR
4. Operator manually `cd`s to the worktree and starts a new session

The PR-work dispatch kind automates step 4 — the subagent starts the worktree session automatically. The operator can then `opencode attach` to watch or join if they want.

### Open questions

1. Should the PR chronicle be comments or body updates? Comments are safer (append-only). Body updates are more visible but racy.
2. Should the subagent worktree be cleaned up on completion? The branch+PR remain on the remote, so the worktree can be cleaned up safely.
3. What permissions does the subagent need? `gh pr create`, `gh pr edit`, `gh pr ready`, `gh issue comment`. All GitHub CLI. The subagent inherits the operator's gh auth.
4. Should there be a `gh pr review --request` at the end to signal the operator? That's a nice touch — the subagent requests review when done.

## Initial thoughts on the template

The template would:
1. Detect serve vs local mode (same as existing templates)
2. `git push origin HEAD:<branch>` (ensure branch exists remotely)
3. `gh pr create --draft --title "<title>" --body "<plan content>"`
4. `opencode run --dir <worktree> [--attach]` with a prompt that tells the subagent:
   - You are working in a PR-tracked worktree
   - Commit and push your changes
   - Update the PR chronicle as you go (via comments)
   - When done, remove the .lock file
5. The orchestrator polls and then does `gh pr review --request-reviewer` optionally

## Next steps

Turn this into a proper plan in docs/plans/. The plan should:
- Define the new `pr-work` dispatch kind
- Include the template `pr-work.sh.j2`
- Update SKILL.md with the new kind
- Add tests
- Possibly add a `gh-pr-comment.sh` helper for chronicle management