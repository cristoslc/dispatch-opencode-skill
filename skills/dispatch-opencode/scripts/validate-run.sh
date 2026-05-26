#!/usr/bin/env bash
# validate-run.sh — post-run validation of a dispatch task directory.
# Exits 0 on healthy completion, non-zero with a diagnosis otherwise.
#
# Expects CLI mode events (opencode run --format json):
#   step_start / step_finish — agent step boundaries
#   text                     — assistant text deltas
# The completion signal is the last step_finish with part.reason == "stop".
#
# Also strips  response blocks from stdout.log and events.jsonl
# (reasoning-model leakage).
#
# Usage: validate-run.sh <task-dir>
# Requires: jq, python3.

set -euo pipefail

err()  { printf 'validate-run: %s\n' "$*" >&2; exit 1; }
warn() { printf 'validate-run: warn %s\n' "$*" >&2; }

[ "$#" -ge 1 ] || err "missing task-dir"
TASK_DIR="$1"

case "$TASK_DIR" in
  /*) ;;
  *)  err "task-dir must be absolute: $TASK_DIR" ;;
esac
case "$TASK_DIR" in
  *[!A-Za-z0-9_./:-]*) err "task-dir contains unsafe characters: $TASK_DIR" ;;
esac
[ -d "$TASK_DIR" ] || err "no such task-dir: $TASK_DIR"

command -v jq      >/dev/null 2>&1 || err "jq is required but not installed"
command -v python3 >/dev/null 2>&1 || err "python3 is required but not installed"

EVENTS="$TASK_DIR/events.jsonl"
STDOUT="$TASK_DIR/stdout.log"

[ -s "$EVENTS" ] || err "events.jsonl missing or empty — likely silent stall"

# CLI mode: opencode run --format json emits step_start / step_finish.
# The completion signal is the last step_finish with part.reason == "stop".
LAST_REASON=$(jq -r 'select(.type=="step_finish") | .part.reason // empty' "$EVENTS" | tail -1)
case "$LAST_REASON" in
  stop) ;;
  "")   err "no step_finish event in stream — likely silent stall" ;;
  tool-calls) err "stream ended on a tool-call step (no final stop)" ;;
  *)    warn "stream ended with step_finish.reason='$LAST_REASON' (not stop)" ;;
esac

if jq -e 'select(.type=="error" or .type=="session.error")' "$EVENTS" >/dev/null 2>&1; then
  warn "error event(s) present — see $EVENTS"
fi

# Strip  thinking… response blocks from captured logs.
strip_think() {
  local target="$1"
  [ -f "$target" ] || return 0
  grep -q ' response' "$target" || return 0
  warn "stripping  response blocks from $target"
  python3 - "$target" <<'PY'
import os, re, sys, tempfile
p = sys.argv[1]
if os.path.islink(p):
    sys.exit(f"refusing to rewrite symlink: {p}")
fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
with os.fdopen(fd, "r", encoding="utf-8", errors="replace") as fh:
    s = fh.read()
s = re.sub(r" <thinking>.*?</thinking>", "", s, flags=re.DOTALL)
s = re.sub(r"  thinking.*?  response\s*", "", s, flags=re.DOTALL)
s = s.replace("  response", "")
d = os.path.dirname(p) or "."
with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, dir=d) as tf:
    tf.write(s)
    tmp = tf.name
os.replace(tmp, p)
PY
}

strip_think "$STDOUT"
strip_think "$EVENTS"

printf 'validate-run: ok task-dir=%s\n' "$TASK_DIR"
