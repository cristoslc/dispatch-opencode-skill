# Code Review Report

**PR:** [PR-work dispatch kind — branch+PR+handoff sashay](https://github.com/cristoslc/dispatch-opencode-skill/pull/1)
**Branch:** `pr-work-dispatch-kind` → `main`
**Date:** 2026-06-09
**Diff:** 539 lines across 8 files
**Platform:** GitHub
**Diff Method:** git-ref-diff
**Dispatch:** specialist

## Models

| Role | Model |
|------|-------|
| Orchestrator | deepseek-v4-flash:cloud |
| Security Agent | inherited |
| Style Agent | inherited |
| Logic Agent | inherited |
| Docs Agent | inherited |
| Project-Memory Agent | inherited |
| Synthesis Agent | inherited |

## Recommendation: **needs_changes**

The PR adds a well-structured pr-work dispatch kind that extends the skill with a full PR-tracked worktree workflow. The core architecture is sound and the code correctly integrates with existing patterns. However, there are 4 high-severity issues to address: a Python code injection vulnerability in template rendering (the most critical concern), a non-executable test file, and a silent git-push failure path that disconnects the PR from the working copy. Additionally, there are documentation gaps (missing `pr_title` field documentation, wrong `gh pr ready` argument in examples) and minor quality issues throughout.

## Finding Counts

| Agent | Count |
|-------|-------|
| Security | 4 |
| Style | 7 |
| Logic | 11 |
| Docs | 5 |
| Project-Memory | 3 |
| **Total** | **30** |

## Merged Findings (22 after dedup)

### 1. [HIGH] Python code injection via WORKTREE_BRANCH in template rendering

- **File:** `scripts/dispatch.sh` (line 165)
- **Source:** security
- **Description:** WORKTREE_BRANCH is interpolated without validation into a double-quoted python3 -c heredoc in dispatch.sh. A single quote in the value breaks out of the Python string literal, enabling arbitrary Python code execution during template rendering. Git allows single quotes, semicolons, and '#' in branch names, so the attack payload survives git validation.
- **Suggested Fix:**
```python
Add character whitelist validation for WORKTREE_BRANCH before template rendering, matching the TASK_ID pattern (case '$WORKTREE_BRANCH' in *[!A-Za-z0-9_.-]*|"") err ... esac). Alternatively, restructure the renderer to pass variables via environment or temp files rather than embedding them in Python source code.
```

### 2. [HIGH] Python code injection via PR_TITLE in template rendering

- **File:** `scripts/dispatch.sh` (line 170)
- **Source:** security
- **Description:** PR_TITLE follows the same interpolation pattern as WORKTREE_BRANCH in the python3 -c heredoc. A single quote in the PR title breaks out of the Python string literal. Additionally, in the rendered template, the PR title flows into `gh pr create --title "$PR_TITLE"` where injection could affect downstream tooling.
- **Suggested Fix:**
```python
Apply the same character whitelist to PR_TITLE, or avoid inline string interpolation in the python3 -c heredoc. Strip ANSI escape sequences and newlines from PR_TITLE before passing to gh pr create --title.
```

### 3. [HIGH] Git push failure silently continues to create PR from stale remote branch

- **File:** `templates/cli/pr-work.sh.j2` (line 35)
- **Source:** logic
- **Description:** When `git push origin HEAD:$BRANCH` fails (e.g., remote branch diverged), the `|| echo` suppresses the error and execution continues to `gh pr create`, creating a PR from potentially stale remote content disconnected from the local working copy.
- **Suggested Fix:**
```bash
git push origin "HEAD:$BRANCH" 2>&1 || {
  echo "[dispatch-opencode] warn: git push failed; skipping PR creation" >&2
  PR_URL=""
}
# Then guard PR creation behind a check
```

### 4. [HIGH] test_pr_work_flow.sh is not executable

- **File:** `tests/test_pr_work_flow.sh` (line 1)
- **Source:** style
- **Description:** The new test file has permissions 644 while existing tests have 755. Cannot be run directly like other tests.
- **Suggested Fix:**
```bash
chmod +x skills/dispatch-opencode/tests/test_pr_work_flow.sh
```

### 5. [MEDIUM] Missing input validation on PR_TITLE parameter

- **File:** `scripts/dispatch.sh` (line 67)
- **Source:** security
- **Description:** PR_TITLE is accepted from the YAML plan without character validation, unlike TASK_ID which is whitelisted to `[A-Za-z0-9_.-]`. An unchecked PR title can contain shell metacharacters, newlines, or control characters.
- **Suggested Fix:** Add a character whitelist for WORKTREE_BRANCH and PR_TITLE. For PR_TITLE, which needs a broader charset, reject control characters (0x00-0x1F excluding tab), null bytes, and ANSI escape sequences.

### 6. [MEDIUM] SKILL.md field listing omits pr_title

- **File:** `SKILL.md` (line 139)
- **Source:** style, docs
- **Description:** The field documentation lists `id`, `kind`, `model`, `prompt`, `target`, `worktree`, and `agent` but does not mention the new `pr_title` field. Also, `worktree` is described as universally optional, but it's required for pr-work.
- **Suggested Fix:** Add `pr_title` to the field listing. Update `worktree` description to note it's required for pr-work.

### 7. [MEDIUM] examples.md: `gh pr ready` uses wrong argument (task ID instead of branch name)

- **File:** `references/examples.md` (line 170)
- **Source:** docs
- **Description:** The example calls `gh pr ready implement-feature`, passing the task ID as the argument. `gh pr ready` accepts `<number | url | branch>`. The actual branch is `feat-123-branch`. The task ID will either fail or match the wrong PR.
- **Suggested Fix:** Change to `gh pr ready feat-123-branch` or add a comment explaining the operator should be on the feature branch.

### 8. [MEDIUM] Git push error stderr merged into stdout log

- **File:** `templates/cli/pr-work.sh.j2` (line 35)
- **Source:** logic
- **Description:** The `2>&1` redirect sends git push's stderr to stdout. An operator checking stderr for errors won't see push failures. Also the warning echo in the `||` handler doesn't use `>&2`, unlike other warnings in the same template.
- **Suggested Fix:** Remove `2>&1` and add `>&2` to the echo in the `||` handler.

### 9. [MEDIUM] Test gh shim does not validate CLI arguments

- **File:** `tests/test_pr_work_flow.sh` (line 48)
- **Source:** logic
- **Description:** The gh shim unconditionally echoes a fake PR URL without inspecting `$@`. The test's grep check only verifies `'gh pr create'` appears somewhere — not that the flags `--draft`, `--title`, or `--body-file` are present.
- **Suggested Fix:** Update the shim to validate required flags.

### 10. [MEDIUM] Missing validation test cases for pr-work edge cases

- **File:** `tests/test_pr_work_flow.sh` (line 1)
- **Source:** logic
- **Description:** Tests are missing for: pr-work without worktree (should fail), pr-work without prompt, and pr-work with target field (should still dispatch correctly).
- **Suggested Fix:** Add adversarial test cases for these edge cases.

### 11. [MEDIUM] Inconsistent rendering style in dispatch.sh pr-work block

- **File:** `scripts/dispatch.sh` (line 169)
- **Source:** style
- **Description:** The pr-work renderer pre-computes `BRANCH_SAFE` and `PR_TITLE_SAFE` as Python variables before the vars dict, while existing renderers call `shlex.quote()` inline inside the dict.
- **Suggested Fix:** Move `shlex.quote()` calls inline into the vars dict for consistency.

### 12. [MEDIUM] run-plan.sh always passes --target for pr-work

- **File:** `scripts/run-plan.sh` (line 114)
- **Source:** style
- **Description:** Unconditionally adds `--target "$TTARGET"` to DISPATCH_ARGS. For pr-work tasks, TTARGET is empty, so `--target ""` is passed. Works because dispatch.sh skips target validation for pr-work, but it's fragile.
- **Suggested Fix:** Conditionally append `--target` only when TTARGET is non-empty.

### 13. [MEDIUM] Worktree isolation not used for implementation work

- **File:** (project-wide)
- **Source:** project-memory-conformance
- **Description:** AGENTS.md requires non-trivial implementation work to happen in a worktree. This PR changes 8 files (360+ lines) across shell, templates, tests, and docs — clearly non-trivial — but was done on a regular branch.
- **Suggested Fix:** Use `git worktree add .worktrees/<name>` for future implementation work.

### 14. [MEDIUM] Readability check failed on plan document

- **File:** `docs/plans/pr-work-dispatch-kind.md`
- **Source:** project-memory-conformance
- **Description:** The plan document scores 13.8 on Flesch-Kincaid grade level (threshold: 10). Unterminated numbered list items inflate the score.
- **Suggested Fix:** Append periods to numbered list items and re-check readability.

### 15. [LOW] Stderr silenced during template rendering

- **File:** `scripts/dispatch.sh` (line 186)
- **Source:** security
- **Description:** `python3 -c "..." 2>/dev/null` suppresses Python tracebacks. If an injection payload causes a SyntaxError, it's hidden from the operator.
- **Suggested Fix:** Redirect Python stderr to a file instead of `/dev/null`.

### 16. [LOW] Dead code in test_pr_work_flow.sh error handler

- **File:** `tests/test_pr_work_flow.sh` (line 83)
- **Source:** style, logic, docs
- **Description:** `err()` calls `exit 1`, so `goto_next=1` is never reached. The `if [ -z "${goto_next:-}" ]` guard is misleading dead code.
- **Suggested Fix:** Remove the `goto_next=1` and the guard, or restructure with a flag variable.

### 17. [LOW] Inconsistent test assertion style (branch survival check)

- **File:** `tests/test_pr_work_flow.sh` (line 137)
- **Source:** style
- **Description:** Uses `|| echo "test: NOTE ..."` instead of the established `ok()`/`err()` pattern used everywhere else.
- **Suggested Fix:** Replace with if/else using `ok()` for pass and a non-fatal note for the expected-skip case.

### 18. [LOW] TSV comment incorrectly states field count

- **File:** `tests/test_tsv_parsing.sh` (line 74)
- **Source:** style
- **Description:** Comment reads "# Verify 7 fields" but assertion checks for 8 fields.
- **Suggested Fix:** Update comment to "# Verify 8 fields".

### 19. [LOW] SESSION_ID extraction via sed regex is fragile

- **File:** `templates/cli/pr-work.sh.j2` (line 70)
- **Source:** logic
- **Description:** Uses `sed` regex on JSON that breaks on formatting changes, key reordering, or escaped characters.
- **Suggested Fix:** Use `python3 -c "import json,sys; ..."` instead.

### 20. [LOW] Missing trailing newlines in template and test files

- **File:** `templates/cli/pr-work.sh.j2` (line 103) and `tests/test_pr_work_flow.sh` (line 144)
- **Source:** logic, project-memory-conformance
- **Description:** Both new files lack trailing newlines (POSIX compliance issue).
- **Suggested Fix:** Append trailing newlines to both files.

### 21. [LOW] Missing 8th-field verification in TSV awk-based test

- **File:** `tests/test_tsv_parsing.sh` (line 84)
- **Source:** logic
- **Description:** The empty-agent and all-fields TSV tests verify columns 4 and 7 via awk but don't verify column 8 (pr_title).
- **Suggested Fix:** Add field 8 verification via awk, and add an IFS round-trip test for a non-default pr_title value.

### 22. [LOW] Whitespace-only branch name would bypass validation

- **File:** `scripts/dispatch.sh` (line 68)
- **Source:** logic
- **Description:** A branch name of only whitespace passes the `-z` check but would fail at `git worktree add`.
- **Suggested Fix:** Trim whitespace or validate branch name format at the YAML parsing stage.

## Per-Agent Detail

### Security — warning

- **[high]** Python code injection via WORKTREE_BRANCH in template rendering (`scripts/dispatch.sh:165`)
- **[high]** Python code injection via PR_TITLE in template rendering (`scripts/dispatch.sh:170`)
- **[medium]** Missing input validation on PR_TITLE parameter (`scripts/dispatch.sh:67`)
- **[low]** Stderr silenced during template rendering (`scripts/dispatch.sh:186`)

*The pr-work dispatch kind introduces a high-severity Python code injection vulnerability through WORKTREE_BRANCH and PR_TITLE. The root cause: bash expands user-controlled variables inside a double-quoted python3 -c heredoc, and single quotes in the value break out of the Python string literal. Unlike TASK_ID (whitelisted to [A-Za-z0-9_.-]), the new parameters enter the template renderer with no validation.*

### Style — warning

- **[high]** test_pr_work_flow.sh is not executable (`tests/test_pr_work_flow.sh:1`)
- **[medium]** SKILL.md field listing omits pr_title (`SKILL.md:139`)
- **[medium]** Inconsistent rendering style in dispatch.sh pr-work block (`scripts/dispatch.sh:169`)
- **[medium]** run-plan.sh always passes --target for pr-work (`scripts/run-plan.sh:114`)
- **[low]** Dead code in test error handler (`tests/test_pr_work_flow.sh:83`)
- **[low]** Inconsistent test assertion style (`tests/test_pr_work_flow.sh:137`)
- **[low]** Stale TSV field count comment (`tests/test_tsv_parsing.sh:74`)

*The code follows the codebase's conventions well (shell quoting, Jinja2 templates, Python inline scripts). The boilerplate duplication across templates is by design per the "one template per kind" constraint.*

### Logic — warning

- **[high]** Git push failure silently continues to create PR from stale remote (`templates/cli/pr-work.sh.j2:35`)
- **[medium]** Git push stderr merged into stdout (`templates/cli/pr-work.sh.j2:35`)
- **[medium]** Test gh shim lacks CLI arg validation (`tests/test_pr_work_flow.sh:48`)
- **[medium]** Missing pr-work edge-case tests (`tests/test_pr_work_flow.sh:1`)
- **[low]** Dead code in test error handler (`tests/test_pr_work_flow.sh:83`)
- **[low]** Fragile SESSION_ID sed extraction (`templates/cli/pr-work.sh.j2:70`)
- **[low]** Missing trailing newline in template (`templates/cli/pr-work.sh.j2:103`)
- **[low]** Missing 8th-field verification in TSV tests (`tests/test_tsv_parsing.sh:84`)
- **[low]** Pipefail portability note (`templates/cli/pr-work.sh.j2:58`)
- **[low]** Missing trailing newline in test (`tests/test_pr_work_flow.sh:144`)
- **[low]** Whitespace-only branch name bypasses validation (`scripts/dispatch.sh:68`)

*The TSV field expansion from 7 to 8 columns is correct at all parsing sites. Template variable interpolation is also correct. The core logic is sound.*

### Documentation — warning

- **[medium]** examples.md: `gh pr ready` uses wrong argument (`references/examples.md:170`)
- **[medium]** SKILL.md fields omit pr_title and don't clarify worktree is required for pr-work (`SKILL.md:139`)
- **[low]** dispatch.sh usage comment omits --pr-title flag (`scripts/dispatch.sh:13`)
- **[low]** Dead code in test control flow (`tests/test_pr_work_flow.sh:83`)
- **[low]** Missing pr_title TSV round-trip test coverage (`tests/test_tsv_parsing.sh:104`)

*Documentation quality is generally good. Inline comments in shell code and test documentation are thorough.*

### Project-Memory Conformance — warning

- **[medium]** Worktree isolation not used for implementation work (project-wide)
- **[medium]** Readability check failed on plan document (`docs/plans/pr-work-dispatch-kind.md:7`)
- **[low]** Missing trailing newlines in new files (templates and tests)

*No violations found for: tk ticket usage, artifact presence (musing and plan exist), or other project rules.*

---

*Review generated by code-review skill with specialist dispatch (5 agents). Generated on 2026-06-09.*