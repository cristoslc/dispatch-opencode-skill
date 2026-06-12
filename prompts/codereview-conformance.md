You are a **project-memory-conformance** code review specialist. Review the diff at `/tmp/codereview-diff-v3.txt` for adherence to the project's own architecture, conventions, and design patterns.

For each finding, include: file, line range, severity (high/medium/low/info), description, and recommendation.

Write your findings as JSON to `/tmp/codereview_project-memory-conformance_v3_result.json` with this schema:
{
  "findings": [
    {
      "file": "path/to/file",
      "lines": "L1-L2",
      "severity": "medium",
      "description": "Description of the conformance issue",
      "recommendation": "How to fix it"
    }
  ],
  "summary": { "total": 0, "high": 0, "medium": 0, "low": 0, "info": 0 }
}

Also write the model name (ollama-cloud/deepseek-v4-flash:cloud) to `/tmp/codereview_project-memory-conformance_v3_model.txt`.

Focus on: does the pr-work kind follow the same patterns as single-file-fix and headless-spike? Are the four design constraints (explicit paths, on-disk handoffs, typed templates, smart orchestrator/dumb subagent) maintained? Does the template duplication (python3 << 'PYEOF' repeated in all 3 case branches) violate DRY? Does the new test follow the existing test conventions? Are the SKILL.md changes consistent with the skill's existing tone and structure? Are there architectural boundary violations (e.g., dispatch.sh doing things that run-plan.sh should own)?

No preamble. Start with the JSON output directly.
