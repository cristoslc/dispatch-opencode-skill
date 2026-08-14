# Watcher daemon exits shortly after start

- **Area:** `skills/dispatch-opencode/scripts/watcher.sh`
- **Severity:** significant
- **Discovered:** 2026-08-13 during E2E for the `--root` path fix (PR #8)
- **Root cause:** The background subshell launched by `watcher.sh start`
  exits shortly after startup, so `status` later reports "stopped" and
  removes the PID file. The daemon does not persist. The watcher-process.sh
  plan-processing loop therefore never runs to completion for background
  dispatch.
- **Impact:** Background (fire-and-forget) dispatch is unreliable. Plans
  dropped into `.subagents/watch/` are not reliably picked up and processed
  because the daemon dies. The `--root` fix (PR #8) is correct and verified,
  but it is not sufficient for background dispatch to work end-to-end until
  this is fixed.
- **Fix approach:** Investigate why the `( ... ) &` background subshell in
  `watcher.sh start` does not persist — likely the `sleep`/loop is being
  torn down, or a parent signal/group issue. Consider proper daemonization
  (setsid/disown), a more robust PID-file write before backgrounding, and a
  restart-tolerant design (adopt orphaned task locks on startup).
- **Risk:** Not fixed inline because it was out of scope for the `--root`
  path fix, carries regression risk to the daemon startup path, and needs
  investigation of the process-lifetime behavior before a safe fix.

## Note

The two failing integration tests (`test_agent_sashay_invocation.sh`,
`test_attach_session_visibility.sh`) are unrelated — the former only
mentions "watcher" in a comment; the latter is attach/session-environment
dependent.
