# Templates

Per-kind dispatch templates. Only files in this directory are referenced
by the skill; empty dirs are not tracked by git.

## `cli/`

Shell templates rendered to `.subagents/<task-id>/start-subagent.sh`. Each
file uses Jinja2 variables from the skill's render step. One `.sh.j2` per
dispatch kind:

| File | Kind | Use |
|------|------|-----|
| `single-file-fix.sh.j2` | `single-file-fix` | Focused edit on one target file. |
| `headless-spike.sh.j2` | `headless-spike` | Read-only investigation, writes report file. |

## Adding a kind

1. Write `<kind>.sh.j2` in `cli/`.
2. Add to the table above.
3. Add the kind to SKILL.md's dispatch kinds table.
4. Add an invocation example to `references/examples.md`.