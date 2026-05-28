# Developer Workflows

## Local development

```sh
# Clone and enter
git clone <repo-url>
cd dispatch-opencode-skill

# Verify toolchain
bash --version && git --version && python3 --version
python3 -c "import yaml; print('ok')"
opencode version
```

## Running tests

```sh
# All integration tests
for t in skills/dispatch-opencode/tests/test_*.sh; do
  bash "$t"
done

# Single test
bash skills/dispatch-opencode/tests/test_worktree_lifecycle.sh
bash skills/dispatch-opencode/tests/test_lock_watch_cycle.sh

# Keep temp dirs for inspection (don't cleanup on exit)
bash skills/dispatch-opencode/tests/test_worktree_lifecycle.sh --keep
```

Tests create temporary git repos under `/tmp/` and clean up on exit
unless `--keep` is passed.

## Running dispatch manually

```sh
# Single task
bash skills/dispatch-opencode/scripts/dispatch.sh \
  single-file-fix \
  /absolute/path/to/repo \
  ollama-cloud/glm-5.1 \
  build \
  /path/to/prompt.md \
  src/target.py \
  --timeout 120

# 1-to-N parallelize
bash skills/dispatch-opencode/scripts/orchestrate.sh \
  --plan .subagents/plan.yaml \
  --timeout 600

# Worktree lifecycle
bash skills/dispatch-opencode/scripts/worktree-prepare.sh \
  --label fix-auth --root /path/to/repo --branch fix-auth-branch
bash skills/dispatch-opencode/scripts/worktree-complete.sh \
  --label fix-auth --root /path/to/repo --commit-msg "fix: auth"
bash skills/dispatch-opencode/scripts/worktree-abandon.sh \
  --label fix-auth --root /path/to/repo
```

## Commit and release

```sh
# Check status
git status
git diff

# Commit — follow conventional commits
git add <files>
git commit -m "feat(scripts): add orchestrate.sh for 1-to-N parallelize"

# Pre-commit hooks run automatically (gitleaks, lint)
```

Releases are cut via the swain-release skill.

## CI

Pre-commit hooks run on every commit. No remote CI pipeline is configured
— this is a skill, not a deployed service. Validation happens locally via
test scripts and pre-commit hooks.

## Detail

- `docs/developer-workflows/` — extended debug guides, troubleshooting