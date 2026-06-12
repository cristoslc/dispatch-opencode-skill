# Golden Traces and CI for Agent Testing

Source: <https://medium.com/@meryemmsakinn/end-vibe-driven-development-testing-ai-agents-in-ci-pipelines-promptfoo-golden-traces-b9b222b23d72>
Fetched: 2026-06-12

## Key concepts

This article introduces "Golden Traces" — frozen records of successful agent
runs used as deterministic fixtures for regression testing.

### Golden Trace concept

A Golden Trace is a frozen record of a successful agent run, consisting of:
- **Input**: The prompt/context that triggered the run
- **Trajectory**: Every tool call, decision point, and state transition
- **Output**: The final response and side effects

The trace is a "blueprint" that provides the deterministic foundation for
regression testing.

### Tool replay proxy for CI determinism

To achieve determinism in CI, the article introduces a ToolReplay pattern:

```python
class ToolReplay:
    def __init__(self, fixture_path=None):
        self.fixtures = json.load(open(fixture_path)) if fixture_path else {}

    def _key(self, tool_name, args):
        blob = json.dumps({"tool": tool_name, "args": args}, sort_keys=True)
        return hashlib.md5(blob.encode()).hexdigest()

    def call(self, tool_name, args, real_call_fn):
        key = self._key(tool_name, args)
        if key in self.fixtures:
            return self.fixtures[key]  # REPLAY (CI)
        return real_call_fn(args)      # LIVE (record mode elsewhere)
```

This is the "record/replay" pattern: in development, use live tool calls and
record them. In CI, replay from fixtures for deterministic testing.

### Policy + Schema + Budgets as merge blockers

In agent testing, the article recommends three layers of CI checks:

1. **Schema**: Does the output match the expected structure? (`is-json`,
   `contains-json`, `jsonschema`)
2. **Policy**: Did the agent call the right tools and avoid forbidden ones?
   (`javascript` custom assertions checking tool_calls)
3. **Budgets**: Did the agent stay within cost and latency limits? (`cost`,
   `latency` thresholds)

```yaml
assert:
  - type: jsonschema
    value: file://schemas/risk_report.schema.json
  - type: javascript
    value: |
      const out = JSON.parse(output);
      const calls = (out.tool_calls || []).map(c => c.name);
      if (!calls.includes("db_lookup")) {
        return { pass: false, score: 0, reason: "db_lookup not called" };
      }
      if (calls.includes("delete_record")) {
        return { pass: false, score: 0, reason: "Forbidden tool: delete_record" };
      }
      return { pass: true, score: 1 };
  - type: javascript
    value: |
      const out = JSON.parse(output);
      if ((out.metrics?.cost_usd ?? 0) > 0.02) {
        return { pass: false, score: 0, reason: "Cost budget exceeded" };
      }
      if ((out.metrics?.latency_s ?? 0) > 4.0) {
        return { pass: false, score: 0, reason: "Latency budget exceeded" };
      }
      return { pass: true, score: 1 };
```

### Workflow: Trace → Filter → Label → Fixture Export → CI Replay

1. Run agent with tracing (Langfuse/Phoenix/OTel)
2. Filter traces for successful runs
3. Label them as golden traces
4. Export fixtures for CI
5. Replay in CI with ToolReplay proxy

### Relevance to dispatch-opencode

- **Golden Traces** → our existing events.jsonl is already a trace artifact.
  A golden trace of a successful sashay invocation could be captured and
  replayed for regression testing.
- **Tool Replay proxy** → our gh shim is already a replay proxy for PR
  creation. We could extend this to replay the entire opencode run.
- **Policy + Schema + Budgets** → our checklist is exactly this pattern:
  schema (plan YAML structure), policy (kind=pr-work, worktree present),
  budget (timeout).
- **CI integration** → our `-n N` compliance measurement could be wired into
  CI with a minimum compliance threshold.