# Automated Structural Testing of LLM-based Agents

Source: <https://arxiv.org/html/2601.18827v1> (Kohl et al., 2026)
Fetched: 2026-06-12

## Key concepts

This paper formalizes structural testing for LLM-based agents — testing the
internal components and interactions rather than just the end-user output
(acceptance testing). It introduces a test automation pyramid for agents.

### The testing pyramid for agents

```
        /\
       /  \        Acceptance tests
      /----\       (end-user perspective, manual eval)
     /      \
    /--------\     Integration tests
   /          \    (agent + tool interactions, mocked LLM)
  /------------\
 /              \ Unit tests
/________________\ (components in isolation)
```

- **Unit tests**: Test individual components (tools, memory, knowledge base)
  in isolation. E.g., "does `search_events(city, date)` return plausible
  values?"
- **Integration tests**: Test interactions between components. E.g., "does
  the agent call `search_events` with correct parameters when mocked LLM
  outputs are fixed?" This is where mocking the LLM enables reproducible
  testing.
- **Acceptance tests**: End-to-end from the user perspective. Expensive,
  hard to automate, and don't facilitate root cause analysis.

### Trace instrumentation

The paper uses OpenTelemetry traces to capture agent trajectories:

```
Expect(traces).spans.with_name("tool.invoke").in_order(["A", "B"])
self.assertTrue(branch_coverage >= 0.8)
```

These traces enable automated verification of structural invariants through
declarative assertions — exactly what our checklist DSL does.

### Constraint satisfaction for plan verification

The paper maps agent plans into constraint satisfaction problems (CSPs).
Synthesized user requirements yield oracles encoding the expected order, timing,
and logical relationships among actions:

```
Plan is erroneous ⟺ UNSAT(C(U) ∪ {observed assignment})
```

This maps to our checklist: the plan YAML must satisfy constraints (kind=pr-work,
worktree present, model present, prompt file exists). Each checklist item is a
constraint.

### Key insight: harness variance confounds measurement

"The same LLM, evaluated on the same benchmark but under different harnesses,
can produce substantially different scores." This is why our test includes
`--attach` detection — the harness (local vs server mode) affects whether the
agent can even run.

### Relevance to dispatch-opencode

- Our checklist DSL is a form of structural assertion over agent trajectories
- The test automation pyramid justifies our approach: unit tests (scripts)
  already exist; our agent acceptance test is an integration test
- Trace instrumentation (OpenTelemetry) parallels our events.jsonl analysis
- CSP-based plan verification maps to our YAML schema validation
- The harness variance warning explains why we test both local and server modes