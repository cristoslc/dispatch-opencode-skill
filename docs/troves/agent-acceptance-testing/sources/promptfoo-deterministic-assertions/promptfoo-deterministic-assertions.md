# Promptfoo Deterministic Assertions

Source: <https://www.promptfoo.dev/docs/configuration/expected-outputs/deterministic/>
Fetched: 2026-06-12

## Key concepts

Promptfoo provides deterministic assertion types for validating LLM and agent
outputs without model-graded judging. These are fast, free, and reproducible —
the foundation of any agent acceptance test.

### Assertion types relevant to agent acceptance testing

| Type | What it checks |
|------|---------------|
| `contains` / `icontains` | Output contains substring |
| `is-json` | Output is valid JSON (optional schema validation) |
| `is-valid-function-call` | Function call matches JSON schema |
| `is-valid-openai-tools-call` | All tool calls match tools JSON schema |
| `tool-call-f1` | F1 score comparing actual vs expected tool calls |
| `skill-used` | Normalized provider skill metadata contains expected skills |
| `trajectory:tool-used` | Traced tool usage contains expected tools |
| `trajectory:tool-args-match` | Traced tool calls include expected argument payloads |
| `trajectory:tool-sequence` | Tool usage appears in expected order |
| `trajectory:step-count` | Count normalized trajectory steps by type or pattern |
| `trace-span-count` | Count spans matching patterns with min/max thresholds |
| `trace-error-spans` | Detect errors in traces by status codes/attributes |
| `javascript` | Custom JS function validates output |
| `python` | Custom Python function validates output |
| `cost` | Inference cost below threshold |
| `latency` | Latency below threshold (ms) |

### skill-used assertion

Specifically relevant to dispatch-opencode: Promptfoo normalizes skill invocation
metadata from:
- Claude Agent SDK: Skill tool calls
- OpenAI Codex SDK: Command text referencing a local SKILL.md path
- OpenCode SDK: Native skill tool parts

Example:

```yaml
assert:
  - type: skill-used
    value: dispatch-opencode
```

This checks whether the agent routed through the named skill. It distinguishes
"a good answer that happened without the skill" from "an answer produced through
the intended workflow."

### trajectory assertions

Require tracing to be enabled. They check the agent's execution path, not just
the final output:

```yaml
assert:
  - type: trajectory:tool-used
    value: [read_file, edit_file]
  - type: trajectory:tool-sequence
    value: [search, read_file, edit_file]
  - type: trajectory:step-count
    value:
      type: command
      pattern: 'pytest*'
      min: 1
```

### tool-call-f1

Computes F1 score comparing the set of tools called by the LLM against an
expected set. Uses unordered set comparison — only presence matters, not order
or frequency. Threshold defaults to 1.0 (exact match); lower thresholds allow
partial matches.

### Composing assertions

The `assert-set` type groups assertions with a configurable threshold:

```yaml
assert:
  - type: assert-set
    threshold: 0.8
    assert:
      - type: skill-used
        value: dispatch-opencode
      - type: contains
        value: "plan.yaml"
      - type: is-json
```

### Relevance to dispatch-opencode

These assertion types map directly to our checklist DSL:
- `skill-used` → "did the agent invoke dispatch-opencode?"
- `trajectory:tool-used` → "did the agent call run-plan.sh?"
- `is-json` → "is the plan YAML valid?"
- `contains` → "does the output reference the correct artifacts?"
- `javascript`/`python` → custom checklist assertions (file_exists, yaml_field, etc.)

The promptfoo model confirms that deterministic assertions should be the first
layer of any agent acceptance test — cheap, fast, and reproducible — with
model-graded assertions only for subjective quality checks.