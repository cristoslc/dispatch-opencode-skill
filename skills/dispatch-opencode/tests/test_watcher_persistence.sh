#!/usr/bin/env bash
# test_watcher_persistence.sh — verifies the watcher daemon persists after the
# parent `start` process exits: status reports "running" with a live PID past
# the parent-exit window, the PID file points at a live process, and stop
# terminates the daemon and removes the PID file.
#
# Regression test for the `$$`-vs-`$BASHPID` bug in watcher.sh start.
#
# Usage: bash tests/test_watcher_persistence.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHER="$SKILL_DIR/scripts/watcher.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-watcher-persist.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT
PID_FILE="$WORK/.subagents/watcher.pid"
START_LOG="$WORK/start.stderr.log"

# 1. start --root launches the daemon and writes a PID file.
# Capture stderr so we can later compare the daemon's own log PID to the PID file.
"$WATCHER" start --root "$WORK" --interval 1 >/dev/null 2>"$START_LOG" || err "start --root failed"
[ -f "$PID_FILE" ] || err "PID file not created: $PID_FILE"
ok "start --root created PID file"

# 2. Wait past the parent-exit window; daemon must still be running
sleep 4

OUT=$("$WATCHER" status --root "$WORK" 2>/dev/null) || err "status --root failed"
echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" || err "status not valid JSON: $OUT"
echo "$OUT" | grep -q '"status":"running"' || err "daemon did not persist; status: $OUT"
ok "status reports running past parent-exit window"

# 3. PID file PID matches a live process and the status pid
FILE_PID=$(cat "$PID_FILE")
STATUS_PID=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['pid'])")
[ -n "$FILE_PID" ] && kill -0 "$FILE_PID" 2>/dev/null || err "PID file PID $FILE_PID is not alive"
[ "$FILE_PID" = "$STATUS_PID" ] || err "PID file $FILE_PID != status pid $STATUS_PID"
[ "$FILE_PID" != "$$" ] || err "PID file recorded the parent start PID"
ok "PID file PID is live and matches status (persistence verified)"

# 4. The daemon's start log line must report the same PID as the PID file,
# not the parent shell's PID. Regression check for the $$-vs-$BASHPID bug.
LOG_PID=$(grep -o 'daemon started PID=[0-9]*' "$START_LOG" | grep -o '[0-9]*$' || true)
[ -n "$LOG_PID" ] || err "daemon start log line missing; log: $(cat "$START_LOG")"
[ "$LOG_PID" = "$FILE_PID" ] || err "log PID $LOG_PID != PID file PID $FILE_PID"
[ "$LOG_PID" != "$$" ] || err "log recorded the parent start PID"
ok "daemon log PID matches PID file PID (log not using parent PID)"

# 5. stop --root terminates the daemon and removes the PID file
"$WATCHER" stop --root "$WORK" >/dev/null 2>&1 || err "stop --root failed"
[ ! -f "$PID_FILE" ] || err "PID file not removed after stop"
OUT=$("$WATCHER" status --root "$WORK" 2>/dev/null) || err "status after stop failed"
echo "$OUT" | grep -q '"status":"stopped"' || err "status not stopped after stop: $OUT"
ok "stop terminated daemon and removed PID file"

echo "test: all checks passed"
