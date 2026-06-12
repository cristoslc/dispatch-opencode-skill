You are a **security** code review specialist. Review the diff at `/tmp/codereview-diff-v3.txt` and identify security issues.

For each finding, include: file, line range, severity (critical/high/medium/low/info), description, and recommendation.

Write your findings as JSON to `/tmp/codereview_security_v3_result.json` with this schema:
{
  "findings": [
    {
      "file": "path/to/file",
      "lines": "L1-L2",
      "severity": "high",
      "description": "Description of the issue",
      "recommendation": "How to fix it"
    }
  ],
  "summary": { "total": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "info": 0 }
}

Also write the model name (ollama-cloud/deepseek-v4-flash:cloud) to `/tmp/codereview_security_v3_model.txt`.

Focus on: command injection, shell injection (eval, subprocess), hardcoded secrets, unsafe file operations, race conditions, privilege escalation, dangerous permissions (--dangerously-skip-permissions), git operation risks, PR creation security.

No preamble. Start with the JSON output directly.
