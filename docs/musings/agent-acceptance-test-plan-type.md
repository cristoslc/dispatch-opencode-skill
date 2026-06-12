# Agent Acceptance Test Plan Type

Date: 2026-06-12

Trove: agent-acceptance-testing@542e25f

## The problem

We just wrote `test_agent_sashay_invocation.sh` — a test that spawns a real
opencode session as a "calling agent" and checks whether it correctly invokes
dispatch-opencode when given sashay guidance. Writing it was painful:

- **Boilerplate avalanche.** Every agent acceptance test needs the same
  scaffold: temp repo, git init, fixture files, gh shim, prompt assembly,
  artifact checking, cleanup. We wrote ~400 lines for one 9-item checklist.

- **Fragile orchestration.** The test must detect whether `opencode serve` is
  running, construct `--attach` args, pipe in a prompt file, and wait for the
  agent to finish. Get any of this wrong and the test silently passes without
  actually testing anything (we saw "Session not found" and zero artifact
  creation before fixing `--attach`).

- **No reusable prompt assembly.** The test builds the calling-agent prompt
  by catting SKILL.md and examples.md into a temp file. Every future test will
  repeat this pattern with slight variations.

- **Compliance measurement is ad hoc.** The checklist counter system
  (C1_PASS, C2_PASS, etc.) is hand-rolled bash. It works, but it's not
  composable — you can't combine checklists across test files or compare
  runs.

- **The skill boundary is untested by default.** The existing tests
  (test_pr_work_flow.sh, UAT, etc.) test the *scripts* — dispatch.sh,
  run-plan.sh, poll-subagent.sh. They never test whether an *agent* can
  correctly invoke the skill. This is the most important seam, and it has
  zero coverage unless someone writes a bespoke test.

## The insight

The sashay test is really two things smashed together:

1. **A test harness** — repo setup, shim installation, opencode invocation,
   cleanup. This is generic. Every agent acceptance test needs it.

2. **A compliance checklist** — did the agent write plan.yaml? Did it use
   kind: pr-work? Did it invoke run-plan.sh? This is domain-specific to the
   skill's contract.

The harness should live inside the skill. The checklist is defined per test
case. This is exactly the structure that a plan type would give us.

## Proposal: `agent-acceptance-test` plan type

Add a fourth dispatch kind to dispatch-opencode:

```yaml
tasks:
  - id: test-sashay-invocation
    kind: agent-acceptance-test
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/test-sashay-invocation.md
    checklist:
      - id: plan-yaml-created
        description: "Plan YAML file exists at the expected path"
        check: "file_exists:plan.yaml"
      - id: kind-is-pr-work
        description: "Plan YAML has kind: pr-work"
        check: "yaml_field:plan.yaml:tasks[0].kind:pr-work"
      - id: prompt-file-exists
        description: "Prompt file referenced in plan YAML exists on disk"
        check: "yaml_field_resolves:plan.yaml:tasks[0].prompt"
      - id: dispatch-happened
        description: ".subagents/<task-id> directory exists"
        check: "subagents_dir_exists"
```

### What the plan type provides

1. **Template `agent-acceptance-test.sh.j2`** — generates a start-subagent.sh
   that:
   - Sets up a temp git repo with fixtures
   - Installs a gh shim
   - Assembles the calling-agent prompt (injects SKILL.md + examples
     automatically, so the test author only writes the scenario)
   - Invokes `opencode run` with `--attach` detection
   - Waits for completion (reusing poll-subagent.sh logic)
   - Runs the compliance checklist
   - Writes results to FINAL_OUTPUT.md as structured data

2. **Checklist DSL** — a small language for artifact assertions:
   - `file_exists:<path>` — file exists in the worktree
   - `yaml_field:<path>:<jq-like-path>:<expected>` — YAML field equals value
   - `yaml_field_resolves:<path>:<jq-like-path>` — YAML field points to
     an existing file
   - `subagents_dir_exists` — `.subagents/<task-id>` exists
   - `branch_exists:<name>` — git branch was created
   - `file_contains:<path>:<pattern>` — file contains a regex pattern
   - `compliance_rate` — overall pass rate across all checks

3. **Built-in N-run support.** The template can run the checklist N times and
   aggregate compliance rates. No more hand-rolled bash counters.

4. **Compliance report in FINAL_OUTPUT.md.** Instead of stdout printing,
   the test writes structured results:

   ```markdown
   # Agent Acceptance Test Results

   test_id: test-sashay-invocation
   runs: 5
   overall_compliance: 85%
   checklist:
     - id: plan-yaml-created
       pass: 5
       fail: 0
       rate: 100%
     - id: kind-is-pr-work
       pass: 4
       fail: 1
       rate: 80%
   ```

### Why this belongs in the skill

The test harness is deeply coupled to dispatch-opencode's internals — how
run-plan.sh is invoked, what artifacts it produces, how .subagents/ is laid
out, how opencode run is called with `--attach` detection. If these change,
the harness must change. Embedding the harness in the skill keeps it in sync.

External test suites can still write their own tests. This plan type just
provides the standard scaffold so that adding a new agent acceptance test is
a matter of writing a prompt and a checklist, not 400 lines of bash.

### How it changes the existing test

The `test_agent_sashay_invocation.sh` we just wrote would shrink from ~400
lines to roughly:

```yaml
tasks:
  - id: test-sashay-invocation
    kind: agent-acceptance-test
    model: ollama-cloud/deepseek-v4-flash:cloud
    agent: build
    prompt: prompts/test-sashay-invocation.md
    runs: 5
    checklist:
      - id: plan-yaml-created
        description: "Plan YAML file created"
        check: file_exists:plan.yaml
      - id: kind-is-pr-work
        description: "Plan uses pr-work kind"
        check: yaml_field:plan.yaml:tasks[0].kind:pr-work
      - id: worktree-field
        description: "Plan has worktree field"
        check: yaml_field_present:plan.yaml:tasks[0].worktree
      - id: prompt-resolves
        description: "Prompt file referenced in plan exists"
        check: yaml_field_resolves:plan.yaml:tasks[0].prompt
      - id: model-field
        description: "Plan has model field"
        check: yaml_field_present:plan.yaml:tasks[0].model
      - id: dispatch-happened
        description: "Subagent was dispatched"
        check: subagents_dir_exists
      - id: gh-pr-create
        description: "Start script has gh pr create"
        check: file_contains:.subagents/{task_id}/start-subagent.sh:gh pr create
      - id: branch-created
        description: "Worktree branch created"
        check: branch_exists:{worktree}
      - id: prompt-copied
        description: "Prompt copied to task dir"
        check: file_exists:.subagents/{task_id}/prompt.md
```

And the prompt file would be:

```markdown
Fix the bug in src/foo.py: the add() function returns a - b instead of a + b.

A sashay has been started for this fix:
- Branch: fix-add-sashay
- Draft PR: https://github.com/test/repo/pull/42

You're continuing the sashay from the orchestrator role. The branch and draft PR
already exist. Your job is to dispatch a subagent into the worktree to do the
actual implementation.

Do NOT edit the source file yourself. You are the orchestrator.
```

The `{run_plan_path}`, `{task_id}`, and `{worktree}` placeholders are
resolved by the template engine at dispatch time.

## What this does NOT change

- The existing script-mechanics tests (UAT, poll, dispatch refactor, etc.)
  remain as-is. They test the scripts directly, not the agent invocation seam.
- The `test_pr_work_flow.sh` test remains. It tests pr-work dispatch mechanics
  without an agent in the loop.
- The skill's core dispatch kinds (single-file-fix, multi-file-fix,
  headless-spike, pr-work) are unchanged. `agent-acceptance-test` is additive.

## Open questions

- Should the checklist DSL support negative assertions (file does NOT exist)?
  Probably yes — "agent did NOT edit src/foo.py directly" is a valid check.
- Should `runs: N` default to 1 or 3? Single run for CI, multi-run for
  compliance measurement. Default 1, allow override.
- Should compliance below a threshold cause exit 1? Configurable per-test
  `min_compliance` field (default 100%).
- Where does the gh shim come from? The template should auto-generate it from
  the plan's `pr_title` field, or the test author provides it as a fixture.