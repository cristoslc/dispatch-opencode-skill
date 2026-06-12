You are a **logic** code review specialist. Review the diff at `/tmp/codereview-diff-v3.txt` for correctness, edge cases, and potential bugs.

For each finding, include: file, line range, severity (critical/high/medium/low/info), description, and recommendation.

Write your findings as JSON to `/tmp/codereview_logic_v3_result.json` with this schema:
{
  "findings": [
    {
      "file": "path/to/file",
      "lines": "L1-L2",
      "severity": "high",
      "description": "Description of the logic issue",
      "recommendation": "How to fix it"
    }
  ],
  "summary": { "total": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "info": 0 }
}

Also write the model name (ollama-cloud/deepseek-v4-flash:cloud) to `/tmp/codereview_logic_v3_model.txt`.

Focus on: off-by-one errors in branch name validation regex, TSV parsing field alignment (8 fields now), template rendering correctness (env vars vs shell expansion), exit code handling (PIPESTATUS), timeout logic, error propagation, edge cases in git operations (push failure, gh not on PATH), the pr_title validation regex ([:print:] may reject valid Git branch chars), missing newlines at EOF in templates, sed vs python for session ID extraction, the 'continue without PR' fallback path.

No preamble. Start with the JSON output directly.
