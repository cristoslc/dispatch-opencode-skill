You are a **memory/resource management** code review specialist. Review the diff at `/tmp/codereview-diff-v3.txt` for resource leaks, process lifecycle issues, and state management.

For each finding, include: file, line range, severity (critical/high/medium/low/info), description, and recommendation.

Write your findings as JSON to `/tmp/codereview_memory_v3_result.json` with this schema:
{
  "findings": [
    {
      "file": "path/to/file",
      "lines": "L1-L2",
      "severity": "medium",
      "description": "Description of the resource issue",
      "recommendation": "How to fix it"
    }
  ],
  "summary": { "total": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "info": 0 }
}

Also write the model name (ollama-cloud/deepseek-v4-flash:cloud) to `/tmp/codereview_memory_v3_model.txt`.

Focus on: trap/cleanup handlers (multiple exit paths), temp file cleanup (mktemp in test), lockfile lifecycle, PID tracking for subagent kill, orphaned processes if timeout kills the harness but not the subagent, worktree cleanup on failure, stderr.log growing unbounded, events.jsonl being tee'd to both stdout.log and itself (possible duplication), the cleanup trap not handling every exit path.

No preamble. Start with the JSON output directly.
