# Promptfoo: Test Agent Skills

Source: <https://www.promptfoo.dev/docs/guides/test-agent-skills/>
Fetched: 2026-06-12

## Key concepts

Promptfoo's agent skill testing guide is the most directly relevant prior art.
It addresses how to test that an AI agent correctly invokes a named skill
(SKILL.md) when given a task that matches the skill's trigger.

### skill-used assertion

The `skill-used` assertion checks normalized provider skill metadata rather
than the model's final output. It works for agent evals where the question is
"did the agent route through the right skill?"

Promptfoo normalizes skill invocations from:
- **Claude Agent SDK**: Skill tool calls
- **OpenAI Codex SDK**: Command text referencing a local SKILL.md path
- **OpenCode SDK**: Native skill tool parts

```yaml
assert:
  - type: skill-used
    value: dispatch-opencode
```

This distinguishes "a good answer that happened without the skill" from "an
answer produced through the intended workflow" — exactly our problem.

### Layered assertions

"Add secondary signals" — start with skill-used, then add correctness checks:

```yaml
defaultTest:
  assert:
    - type: skill-used
      value: dispatch-opencode
    - type: javascript
      threshold: 0.7
      value: |
        const result = typeof output === 'string' ? JSON.parse(output) : output;
        const expected = context.vars.expectedIssues;
        const found = (result.issues || []).map((issue) => issue.id);
        const hits = expected.filter((id) => found.includes(id));
        const recall = hits.length / expected.length;
        return {
          pass: recall >= 0.75,
          score: recall,
          reason: `matched ${hits.length}/${expected.length} expected issues`,
        };
```

### Trajectory assertions for skill verification

For Codex SDK, trace evidence verifies the agent read the skill file:

```yaml
tests:
  - assert:
      - type: trajectory:step-count
        value:
          type: command
          pattern: '*review-standards/SKILL.md*'
          min: 1
```

### Relevance to dispatch-opencode

The `skill-used` assertion type maps directly to our C1 check ("did the agent
invoke dispatch-opencode?"). Our test goes further by checking the artifacts
the skill produced, but skill-used is the entry-point assertion.

The layered assertion pattern (skill-used → correctness checks) is exactly
our checklist model: C1 (plan created) → C2-C5 (plan correctness) → C6-C9
(dispatch artifacts).