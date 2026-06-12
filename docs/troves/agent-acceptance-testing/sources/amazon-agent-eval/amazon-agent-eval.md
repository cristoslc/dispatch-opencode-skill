# Amazon Agent Evaluation Framework

Source: <https://aws.amazon.com/blogs/machine-learning/evaluating-ai-agents-real-world-lessons-from-building-agentic-systems-at-amazon/>
Fetched: 2026-06-12

## Key concepts

Amazon's evaluation framework for agentic AI systems addresses two challenges:
(1) the same LLM produces different scores under different harnesses, and
(2) tool invocation correctness must be evaluated alongside output quality.

### Tool schema standardization

"Poorly defined tool schemas and imprecise semantic descriptions result in
erroneous tool selection during agent runtime, leading to the invocation of
irrelevant APIs that unnecessarily expand the context window, increase inference
latency, and escalate computational costs through redundant LLM calls."

Amazon addressed this by creating cross-organizational standards for tool schema
and description formalization — a governance framework specifying mandatory
compliance requirements for all builder teams.

### Golden datasets for regression testing

Amazon teams create "golden datasets" from historical API invocation logs,
generated synthetically using LLMs. These datasets serve as regression tests
for tool-selection and tool-use accuracy after integration.

### Evaluation workflow

The framework standardizes assessment across diverse agent implementations:

1. **Define evaluation criteria** — what constitutes success (functional and
   non-functional requirements)
2. **Create golden datasets** — representative inputs with expected outputs
3. **Run evaluations** — automated execution against the agent
4. **Measure metrics** — task completion, tool invocation accuracy, latency,
   cost
5. **Iterate** — refine prompts, tools, or agent logic based on results

### Evaluation types

- **End-to-end**: Full agent trajectory from user input to final output
- **Trajectory-level**: Check intermediate tool calls and reasoning steps
- **Component-level**: Test individual tools, retrievers, or sub-agents in
  isolation

This maps to our testing pyramid:
- End-to-end → our agent acceptance test (full sashay invocation)
- Trajectory-level → our checklist (intermediate artifact checks)
- Component-level → our existing script tests (dispatch.sh, run-plan.sh)

### Relevance to dispatch-opencode

- **Tool schema standardization** → our plan YAML schema is exactly this:
  mandatory fields (kind, model, prompt, worktree for pr-work) with
  fail-closed validation
- **Golden datasets** → our test fixtures (src/foo.py with the add bug) are
  golden inputs; the expected outputs are our checklist criteria
- **Evaluation types** → our test suite already covers all three levels
  (component tests, trajectory checks, end-to-end agent invocation)