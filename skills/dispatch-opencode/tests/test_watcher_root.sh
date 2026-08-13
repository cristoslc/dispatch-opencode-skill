#!/usr/bin/env bash
# test_watcher_root.sh — verifies watcher.sh requires an explicit --root and
# writes .subagents/ under that root, not under the script's own directory.
#
# Usage: bash tests/test_watcher_root.sh [--keep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHER="$SKILL_DIR/scripts/watcher.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

err() { printf 'test: FAIL %s\n' "$*" >&2; exit 1; }
ok()  { printf 'test: PASS %s\n' "$*"; }

WORK=$(mktemp -d /tmp/oc-watcher-root.XXXXXX)
trap '[ "$KEEP" -eq 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

# 1. status --root with no daemon running prints stopped + valid JSON
OUT=$("$WATCHER" status --root "$WORK" 2>/dev/null) || err "status --root failed"
echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" || err "status --root not valid JSON: $OUT"
echo "$OUT" | grep -q '"status":"stopped"' || err "status --root not stopped: $OUT"
ok "status --root reports stopped with valid JSON"

# 2. start --root creates PID file and watch dirs under <root>/.subagents/
"$WATCHER" start --root "$WORK" >/dev/null 2>&1 || err "start --root failed"
[ -f "$WORK/.subagents/watcher.pid" ] || err "PID file not under root: $WORK/.subagents/watcher.pid"
[ -d "$WORK/.subagents/watch/processing" ] || err "watch/processing not under root"
[ -d "$WORK/.subagents/watch/completed" ] || err "watch/completed not under root"
[ -d "$WORK/.subagents/watch/failed" ] || err "watch/failed not under root"
[ -d "$WORK/.subagents/watch/results" ] || err "watch/results not under root"
[ ! -d "$SKILL_DIR/.subagents" ] || err ".subagents created under script dir: $SKILL_DIR/.subagents"
ok "start --root created PID file and watch dirs under root"

# 3. stop --root stops the daemon and removes the PID file
"$WATCHER" stop --root "$WORK" >/dev/null 2>&1 || err "stop --root failed"
[ ! -f "$WORK/.subagents/watcher.pid" ] || err "PID file not removed after stop"
ok "stop --root stopped daemon and removed PID file"

# 4. status without --root exits non-zero with an error message
if "$WATCHER" status >/dev/null 2>&1; then
  err "status without --root should exit non-zero"
fi
OUT=$("$WATCHER" status 2>&1 >/dev/null) || true
echo "$OUT" | grep -qi "root" || err "status without --root lacks error message: $OUT"
ok "status without --root fails loudly with error message"

echo "test: all checks passed"
