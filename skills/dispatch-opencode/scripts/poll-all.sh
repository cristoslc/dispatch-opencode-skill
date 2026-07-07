#!/usr/bin/env bash
# poll-all.sh — poll all active tasks in a project root, return summary JSON.
#
# Scans .subagents/*/.lock for active tasks, checks events line count and
# mtime for each, and returns a consolidated JSON report on stdout.
#
# Usage:
#   poll-all.sh --root <project-root> [--interval <sec>] [--max-polls <n>]
#
# When --interval and --max-polls are provided, the script loops: polls all
# tasks, sleeps, repeats until all tasks complete or max polls reached.
# Without them, it runs a single scan and exits.
#
# Exit codes:
#   0 — all tasks completed (no locks found)
#   1 — one or more tasks still active
#
# Output (stdout):
#   {"tasks":[{"id":"...","lines":N,"mtime":epoch,"age_sec":N},...],
#    "active":N,"completed":N}

set -euo pipefail

err() { printf 'poll-all: %s\n' "$*" >&2; exit 1; }
log() { printf 'poll-all: %s\n' "$*" >&2; }

ROOT=""
INTERVAL=""
MAX_POLLS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)      ROOT="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --max-polls) MAX_POLLS="$2"; shift 2 ;;
    *)           err "unknown flag: $1" ;;
  esac
done

[ -n "$ROOT" ] || err "--root is required"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || err "root does not exist: $ROOT"

scan_tasks() {
  local tasks_json="["
  local first=1
  local active=0
  local completed=0

  for lock in "$ROOT/.subagents"/*/.lock; do
    [ -f "$lock" ] || continue
    local task_dir
    task_dir="$(dirname "$lock")"
    local tid
    tid="$(basename "$task_dir")"
    local events="$task_dir/events.jsonl"

    local lines=0
    local mtime=0
    if [ -f "$events" ]; then
      lines=$(wc -l < "$events" | tr -d ' ')
      mtime=$(stat -f %m "$events" 2>/dev/null || stat -c %Y "$events" 2>/dev/null || echo 0)
    fi

    local now
    now=$(date +%s)
    local age_sec=$(( now - mtime ))

    [ "$first" -eq 1 ] && first=0 || tasks_json+=","
    tasks_json+="{\"id\":\"$tid\",\"lines\":$lines,\"mtime\":$mtime,\"age_sec\":$age_sec}"
    active=$((active + 1))
  done

  tasks_json+="]"
  printf '{"tasks":%s,"active":%d,"completed":%d}\n' "$tasks_json" "$active" "$completed"
}

# Single scan mode
if [ -z "$INTERVAL" ] && [ -z "$MAX_POLLS" ]; then
  scan_tasks
  result=$(scan_tasks)
  echo "$result"
  active=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['active'])")
  [ "$active" -eq 0 ] && exit 0 || exit 1
fi

# Poll loop mode
[ -n "$INTERVAL" ] || INTERVAL=30
[ -n "$MAX_POLLS" ] || MAX_POLLS=20

for i in $(seq 1 "$MAX_POLLS"); do
  result=$(scan_tasks)
  active=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['active'])")
  log "poll $i/$MAX_POLLS active=$active"

  if [ "$active" -eq 0 ]; then
    echo "$result"
    log "all tasks completed"
    exit 0
  fi

  if [ "$i" -lt "$MAX_POLLS" ]; then
    sleep "$INTERVAL"
  fi
done

# Max polls reached — report current state
result=$(scan_tasks)
echo "$result"
log "timeout: $MAX_POLLS polls reached, $active tasks still active"
exit 1
