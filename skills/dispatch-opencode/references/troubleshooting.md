# dispatch-opencode Troubleshooting

Spoke file for dispatch-opencode skill. Loaded when troubleshooting
subagent dispatch issues. Trigger keywords: `session not found`,
`blank FINAL_OUTPUT.md`, `dispatch skipped`, `timeout`, `stuck`,
`exit code 3`, `exit code 2`, `branch not found`, `orphaned symlink`,
`worktree symlink`, `prompt file resolves`.

---

### "Session not found" or blank FINAL_OUTPUT.md

The `--attach` mode tells opencode to connect to a running server at
`OPENCODE_SERVER_URL`. When the server uses password auth but the
subagent does not have the password, opencode silently creates a
_local_ session instead of attaching. The subagent finishes, but
FINAL_OUTPUT.md is empty or contains no text events.

**Fix:** Set `OPENCODE_SERVER_PASSWORD` to match the server's password
before running `run-plan.sh`. Both `OPENCODE_SERVER_URL` and
`OPENCODE_SERVER_PASSWORD` must be set in the parent shell environment.
The templates pass them through to the subagent automatically.

Confirm the server has auth enabled by checking its startup log for
"HTTP basic auth enabled". If it is missing, restart `opencode serve`
with `OPENCODE_SERVER_PASSWORD=<password>` set.

### Dispatch skipped with "prompt file resolves to the same path"

The plan's `prompt` path points into `.subagents/<task-id>/` which is
the same directory dispatch.sh copies it to. BSD `cp` on macOS rejects
this.

**Fix:** Store prompt files in `prompts/<task-id>.md` at the project
root and reference them as `prompt: prompts/<task-id>.md` in the plan.

### Subagent times out (exit code 3 from poll-subagent.sh)

The `poll-subagent.sh` default is 12 polls at 15s intervals = 180s.
Complex tasks may need more time.

**Fix:** Pass `--max-polls 40` to `poll-subagent.sh`, or set the
`timeout` primitive in the dispatch template for longer wall-clock
time.

### Subagent stuck (exit code 2 from poll-subagent.sh)

The events.jsonl line count and mtime have not changed for
`--stale-threshold` seconds (default 60). The subagent process
may be hung.

**Fix:** Check `stderr.log` and `events.jsonl` in `.subagents/<id>/`
for errors. Kill the PID manually and call
`subagent-abandon.sh --task-id <id> --root <project-root>`.

### subagent-abandon.sh reports "branch not found"

The task did not use a worktree branch — only `pr-work` and tasks
with an explicit `worktree:` field create one. The "not found" message
is informational; cleanup still succeeds.

### Worktree symlink points to a missing directory

The `.worktrees/<id>` symlink survives when the `.subagents/<id>` task
dir is removed without calling `subagent-cleanup.sh`.

**Fix:** Run `cleanup-stale.sh` from the project root to detect and
remove orphaned symlinks.