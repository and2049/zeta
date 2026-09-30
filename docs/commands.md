# Prompt templates

A prompt template is a Markdown file that becomes a slash command. Typing
`/review src/main.zig` in the full-screen client expands `review.md` with its
arguments and sends the result as an ordinary message. The session history
keeps the expanded text.

## Where templates live

Each `prompts/` directory is read directly (subdirectories are ignored), in
priority order; a later directory replaces a template with the same name:

1. `~/.agents/prompts` (user)
2. `~/.config/zeta/prompts` (user)
3. `<project>/.agents/prompts` (project)
4. `<project>/.zeta/prompts` (project)

The file name without `.md` is the command name. Templates are read again for
every listing and every run, so edits apply immediately with no reload.

These files are skipped, with a diagnostic in `zeta_inspect` (`diagnostics`)
and `GET /registry`:

- files larger than 1 MiB
- names containing whitespace
- names of the client's built-in commands: `new`, `resume`, `model`,
  `connect`, `rename`, `delete`, `reload`, `attach`, `pending`, `help`, `quit`
- frontmatter lines that are not `key: value`
- templates past the first 512 in one directory

## Format

```markdown
---
description: Review a file for bugs
argument-hint: <path> [focus]
---
Review $1 for ${2:-correctness}. Report problems with line numbers.
```

Frontmatter is optional. `description` falls back to the first nonblank line
of the body, cut to 60 characters with `...`. `argument-hint` is shown in
completion. Other keys are ignored. The body, trimmed, is the template.

## Arguments

Arguments are split on whitespace. Single or double quotes group words and
are removed; there are no backslash escapes, and an unclosed quote takes the
rest of the line.

| Placeholder | Expands to |
| --- | --- |
| `$1`, `$2`, … | one argument; empty when missing |
| `$@`, `$ARGUMENTS` | all arguments joined by spaces |
| `${N:-default}` | argument N, or `default` when missing or empty |
| `${@:-default}`, `${ARGUMENTS:-default}` | all arguments, or `default` |
| `${@:N}` | arguments from the Nth on |
| `${@:N:L}` | L arguments starting at the Nth |

Substitution is a single pass: text inserted from an argument is not expanded
again. Arguments the template does not reference are dropped. Templates cannot
run shell commands.

## Running templates

In the full-screen client, typing `/` lists the built-in commands, then the
templates with their argument hint, description and source (`user` or
`project`). Enter on `/name arguments` runs the template when one exists;
anything else starting with `/` is sent as ordinary text. `zeta run` sends its
text as is and does not run templates.

Over HTTP, `GET /commands?location=` lists templates and
`POST /sessions/:id/command` runs one; see [protocol](protocol.md).

## Other commands

Extensions register commands of their own, and each MCP server's prompts
become commands named `<server>:<prompt>` (see [MCP servers](mcp.md#prompts)).
They are listed with the templates in `GET /commands`.
