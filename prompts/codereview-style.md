You are a **style** code review specialist. Review the diff at `/tmp/codereview-diff-v3.txt` for coding style, formatting, and convention issues.

For each finding, include: file, line range, severity (high/medium/low/info), description, and recommendation.

Write your findings as JSON to `/tmp/codereview_style_v3_result.json` with this schema:
{
  "findings": [
    {
      "file": "path/to/file",
      "lines": "L1-L2",
      "severity": "low",
      "description": "Description of the issue",
      "recommendation": "How to fix it"
    }
  ],
  "summary": { "total": 0, "high": 0, "medium": 0, "low": 0, "info": 0 }
}

Also write the model name (ollama-cloud/deepseek-v4-flash:cloud) to `/tmp/codereview_style_v3_model.txt`.

Focus on: shell script conventions (bash best practices), shellcheck guidelines, indentation, naming consistency, trailing whitespace, missing newlines at EOF, inconsistent quoting, heredoc usage, error handling patterns in shell scripts, markdown formatting, YAML conventions.

No preamble. Start with the JSON output directly.
