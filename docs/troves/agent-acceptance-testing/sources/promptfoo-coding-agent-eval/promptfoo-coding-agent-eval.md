# Promptfoo: Evaluate Coding Agents

Source: <https://www.promptfoo.dev/docs/guides/evaluate-coding-agents/>
Fetched: 2026-06-12

## Key concepts

Promptfoo's coding agent evaluation guide addresses the same problem space as
agent acceptance testing: how do you test that an agent actually does what it's
supposed to when it can take arbitrary actions?

### Testing philosophy

- "Test the system, not the model. 'What is a linked list?' tests knowledge.
  'Find all linked list implementations in this codebase' tests agent
  capability."
- "Measure objectively. 'Is the code good?' is subjective. 'Did it find the 3
  intentional bugs?' is measurable."
- "Assert the path when the path matters. If the requirement is 'ran tests,'
  'asked for approval,' or 'used the MCP tool,' do not rely only on the final
  answer."

### Tracing vs output assertions

When you need to verify behavior rather than the agent's self-report, tracing
is the better fit. It lets you assert that the agent actually ran tests,
executed commands, or took multiple reasoning steps:

```yaml
tracing:
  enabled: true
  otlp:
    http:
      enabled: true

tests:
  - assert:
      - type: trajectory:step-count
        value:
          type: command
          pattern: 'pytest*'
          min: 1
      - type: trajectory:step-count
        value:
          type: reasoning
          min: 1
```

### Non-determinism handling

- Run evals multiple times with `--repeat 3` to measure variance
- Write flexible assertions that accept equivalent phrasings
- "If a prompt fails 50% of the time, the prompt is ambiguous. Fix the
  instructions rather than running more retries."
- Token distribution reveals intent: "High prompt tokens + low completion
  tokens means the agent is reading files. The inverse means you're testing the
  model's generation, not the agent's capabilities."

### Cost and latency thresholds

```yaml
assert:
  - type: cost
    threshold: 0.50
  - type: latency
    threshold: 30000
```

### Sandbox and safety

- "Keep tests in disposable or read-only workspaces unless the expected side
  effect is part of the test."
- "Never give agents access to production credentials, real customer data, or
  network access to internal systems."

### JavaScript assertions for structural checks

```yaml
assert:
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
```

This pattern — checking that required tools were called and forbidden tools
were not — maps directly to our checklist DSL's `subagents_dir_exists` and
`file_contains` checks.

### Relevance to dispatch-opencode

The coding agent eval pattern maps to our agent acceptance test:
1. **Disposable workspaces** → our temp git repos with gh shims
2. **Tracing assertions** → our checklist checks on artifacts
3. **Tool-call verification** → our checks that run-plan.sh was invoked
4. **Cost/latency thresholds** → our timeout mechanism
5. **--repeat N for variance** → our `-n N` compliance measurement