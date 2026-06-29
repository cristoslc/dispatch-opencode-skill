#!/usr/bin/env bash
# verify-cwd.sh — fail-closed CWD verification for dispatch-opencode.
# Exits 0 only if PATH_ARG is an absolute, existing git work tree that
# matches the expected branch and/or worktree label, and (when worktree
# verification is requested) is rooted under the configured worktree-root.
#
# By default, dispatching to a trunk branch (main/master) is REJECTED.
# Pass --dangerously-write-trunk to override.
#
# Usage:
#   verify-cwd.sh <absolute-path> \
#     [--branch <name>] \
#     [--worktree <label> --worktree-root <absolute-root>] \
#     [--dangerously-write-trunk]

set -euo pipefail

err() { printf 'verify-cwd: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 1 ] || err "missing path argument"
PATH_ARG="$1"; shift

EXPECT_BRANCH=""
EXPECT_WORKTREE=""
EXPECT_WORKTREE_ROOT=""
DANGEROUSLY_WRITE_TRUNK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)                 EXPECT_BRANCH="$2"; shift 2 ;;
    --worktree)               EXPECT_WORKTREE="$2"; shift 2 ;;
    --worktree-root)          EXPECT_WORKTREE_ROOT="$2"; shift 2 ;;
    --dangerously-write-trunk) DANGEROUSLY_WRITE_TRUNK=1; shift ;;
    *)                        err "unknown flag: $1" ;;
  esac
done

# Strip a trailing slash so the suffix check below is deterministic.
PATH_ARG="${PATH_ARG%/}"

case "$PATH_ARG" in
  /*) ;;
  *)  err "path must be absolute: $PATH_ARG" ;;
esac
[ -d "$PATH_ARG" ] || err "path does not exist or is not a directory: $PATH_ARG"

cd "$PATH_ARG"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || err "not a git work tree: $PATH_ARG"

ACTUAL_BRANCH="$(git branch --show-current)"
[ -n "$ACTUAL_BRANCH" ] || ACTUAL_BRANCH="(detached)"

if [ -n "$EXPECT_BRANCH" ] && [ "$ACTUAL_BRANCH" != "$EXPECT_BRANCH" ]; then
  err "branch mismatch: expected '$EXPECT_BRANCH', got '$ACTUAL_BRANCH'"
fi

# Reject dispatch to trunk (main/master) unless --dangerously-write-trunk is set.
# This prevents accidental subagent writes to the project root.
if [ "$DANGEROUSLY_WRITE_TRUNK" -eq 0 ]; then
  case "$ACTUAL_BRANCH" in
    main|master)
      err "refusing to dispatch to trunk branch '$ACTUAL_BRANCH' — pass --dangerously-write-trunk to override"
      ;;
  esac
fi

if [ -n "$EXPECT_WORKTREE" ]; then
  # Reject labels containing slashes, glob characters, or anything outside
  # a safe identifier set. Without this, a label of '*' would match every
  # path and a label of '..' would let the suffix check accept paths
  # outside the intended worktree.
  case "$EXPECT_WORKTREE" in
    *[!A-Za-z0-9_./-]*|"") err "unsafe worktree label: '$EXPECT_WORKTREE'" ;;
  esac

  # Worktree mode requires an explicit absolute root so the suffix check
  # is anchored. Without the root, '/tmp/attacker/<label>' would pass a
  # suffix-only match even though it sits outside the project's
  # worktree tree.
  [ -n "$EXPECT_WORKTREE_ROOT" ] \
    || err "--worktree requires --worktree-root"

  EXPECT_WORKTREE_ROOT="${EXPECT_WORKTREE_ROOT%/}"
  case "$EXPECT_WORKTREE_ROOT" in
    /*) ;;
    *)  err "worktree-root must be absolute: $EXPECT_WORKTREE_ROOT" ;;
  esac

  case "$PATH_ARG" in
    "$EXPECT_WORKTREE_ROOT"/*) ;;
    *) err "path is not under worktree-root '$EXPECT_WORKTREE_ROOT': $PATH_ARG" ;;
  esac

  case "$PATH_ARG" in
    *"/$EXPECT_WORKTREE") ;;
    *) err "worktree label mismatch: expected suffix '/$EXPECT_WORKTREE', got '$PATH_ARG'" ;;
  esac
fi

printf 'verify-cwd: ok path=%s branch=%s\n' "$PATH_ARG" "$ACTUAL_BRANCH"
