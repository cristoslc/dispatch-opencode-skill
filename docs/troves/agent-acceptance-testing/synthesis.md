# Agent Acceptance Testing — Synthesis

## What this trove covers

Techniques, frameworks, and prior art for testing whether an LLM agent correctly
invokes a tool or skill when given a task that should trigger it. This is
distinct from testing the tool itself (unit/integration tests) — it tests the
*invocation seam* between the agent and the tool.

## Key findings

### 1. Three-layer testing pyramid for agents

All sources converge on a testing pyramid for agentic systems:

- **Unit tests**: Test the tool in isolation (our dispatch.sh, run-plan.sh
  tests). Already well-covered.
- **Integration tests**: Test the agent + tool interaction with the LLM mocked
  or replayed. Our agent acceptance test sits here.
- **Acceptance tests**: End-to-end from user perspective. Expensive,
  non-deterministic, hard to automate root cause analysis.

The structural testing paper (Kohl et al.) formalizes this: acceptance tests
"require manual evaluation, are difficult to automate, do not facilitate root
cause analysis, and incur expensive test environments." Integration tests with
deterministic assertions are the sweet spot.

### 2. Deterministic assertions first, model-graded second

Promptfoo's guidance is explicit: "Use deterministic assertions wherever
possible." The hierarchy:

1. **Deterministic** (contains, is-json, regex, javascript) — fast, free,
   reproducible
2. **Model-graded** (llm-rubric) — for subjective quality only
3. **Custom scoring** — domain-specific logic

Our checklist DSL uses only deterministic assertions: file_exists, yaml_field,
yaml_field_resolves, subagents_dir_exists, branch_exists, file_contains. No
model-graded checks needed — the skill invocation contract is fully
deterministic.

### 3. Skill-used as the entry-point assertion

Promptfoo's `skill-used` assertion checks whether the agent routed through a
named skill. This is the first check in our checklist (C1: "plan.yaml exists"
implies the agent invoked run-plan.sh). The `tool-call-f1` metric extends this
to partial matches.

The promptfoo model normalizes skill invocations across providers:
- Claude Agent SDK: Skill tool calls
- OpenAI Codex SDK: Command text referencing SKILL.md
- OpenCode SDK: Native skill tool parts

### 4. Trajectory assertions for behavioral verification

When "the path matters" (did the agent use the right tool, in the right order,
with the right arguments), trajectory assertions verify the execution path:

- `trajectory:tool-used` — did the agent call the expected tools?
- `trajectory:tool-sequence` — did it call them in the right order?
- `trajectory:tool-args-match` — did it pass the right arguments?

Our checklist maps to trajectory assertions:
- C6 (dispatch happened) → `trajectory:tool-used: run-plan.sh`
- C7 (gh pr create in script) → `trajectory:tool-args-match: kind=pr-work`

### 5. Golden Traces for regression testing

The "Golden Trace" pattern (Meryem Sakin article): freeze a successful agent
run as a fixture, then replay it in CI for deterministic regression testing.
The key insight: "If you want determinism in CI, you must freeze tool outputs
just like you freeze code."

The ToolReplay proxy pattern wraps tools in a replay layer:

```python
def call(self, tool_name, args, real_call_fn):
    key = self._key(tool_name, args)
    if key in self.fixtures:
        return self.fixtures[key]  # REPLAY
    return real_call_fn(args)      # LIVE
```

Our gh shim is already a replay proxy. The events.jsonl from a successful
dispatch is already a trace. A natural extension: capture a golden
events.jsonl from a successful sashay invocation and replay it for
regression testing.

### 6. Harness variance confounds measurement

The Holistic Agent Leaderboard paper (cited in Kohl et al.) shows that "the
same LLM, evaluated on the same benchmark but under different harnesses, can
produce substantially different scores." This is why our test detects
`opencode serve` and adjusts `--attach` mode — the harness affects whether
the agent can even run.

### 7. Policy + Schema + Budgets as CI merge blockers

The Golden Traces article recommends three CI layers:

1. **Schema**: Does output match expected structure? → our plan YAML schema
2. **Policy**: Did agent call right tools and avoid forbidden ones? → our
   checklist (kind=pr-work, no direct edits)
3. **Budgets**: Stay within cost/latency limits? → our timeout mechanism

## Points of agreement

All sources agree on:
- Deterministic assertions are the foundation; model-graded is supplementary
- Agent testing requires checking the execution path, not just the final output
- Non-determinism must be measured, not ignored (run N times, measure
  compliance rate)
- Disposable workspaces are essential for safety
- Tool invocation correctness is a distinct test concern from output quality

## Points of disagreement

- **Promptfoo** treats agent evaluation as a configuration problem (YAML
  assertions). Our approach treats it as a skill-internal concern (the
  `agent-acceptance-test` plan type).
- **Kohl et al.** advocate for LLM mocking to achieve reproducibility. We use
  a real LLM and measure compliance rates, accepting non-determinism as
  inherent to the domain.
- **Golden Traces** advocates for record/replay in CI. We currently use live
  runs with compliance measurement. Record/replay could be a future extension.

## Gaps

- **Negative assertions**: Our checklist doesn't yet check that the agent did
  NOT do something (e.g., did NOT edit src/foo.py directly). The musing
  mentions this as an open question; promptfoo supports `not-contains`.
- **Multi-model compliance**: We test with one model. Promptfoo supports
  multi-provider comparison out of the box.
- **CI integration**: Our test is a standalone bash script. Promptfoo has
  built-in CI/CD support with `--output` formats and exit codes.
- **Trace-level debugging**: Our test checks artifacts, not traces. Adding
  events.jsonl assertions would give trajectory-level visibility.

## Source inventory

| Source | Key contribution |
|--------|-----------------|
| promptfoo deterministic assertions | Assertion type taxonomy, skill-used, trajectory assertions |
| promptfoo coding agent eval | Disposable workspaces, tracing, cost/latency thresholds |
| promptfoo skill eval | skill-used assertion, layered assertion pattern |
| Kohl et al. structural testing | Test pyramid for agents, CSP-based plan verification, harness variance |
| Golden Traces article | Tool replay proxy, policy+schema+budgets CI pattern |
| Amazon agent eval | Tool schema standardization, golden datasets, evaluation workflow types |