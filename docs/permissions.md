# Permissions

Add ordered rules to `zeta.jsonc`; the last matching rule wins. Without a matching rule, calls are allowed.

```jsonc
{
  "permission": [
    { "action": "bash", "pattern": "*", "effect": "ask" },
    { "action": "write", "pattern": "*/secrets/*", "effect": "deny" },
    { "action": "external_directory", "pattern": "*", "effect": "ask" }
  ]
}
```

Effects are `allow`, `deny`, and `ask`. In actions and patterns, `*` matches any run of characters (including `/`) and `?` exactly one character; a trailing ` *` may also match nothing, so `git *` covers both `git` and `git status`. The action is the tool name unless the tool declares another. What the pattern matches is declared by each tool as a permission target naming one of its arguments: read/write/edit match canonical absolute paths, bash a command, webfetch a URL (checked again for every redirect target), and skill a skill name. A tool that declares no target is matched with the pattern `*`. Access to a file outside the project additionally checks `external_directory`. `GET /registry` shows each tool's declared permission.

## Examples

Rules are checked in order and the last match wins, so put broad rules first and exceptions after them:

```jsonc
{
  "permission": [
    // Ask before any shell command, but let read-only git and the test suite run.
    { "action": "bash", "pattern": "*", "effect": "ask" },
    { "action": "bash", "pattern": "git status *", "effect": "allow" },
    { "action": "bash", "pattern": "git diff *", "effect": "allow" },
    { "action": "bash", "pattern": "zig build test *", "effect": "allow" },
    // Never touch the environment files, wherever they are.
    { "action": "read", "pattern": "*/.env", "effect": "deny" },
    { "action": "edit", "pattern": "*/.env", "effect": "deny" },
    { "action": "write", "pattern": "*/.env", "effect": "deny" },
    // Only fetch from the docs site.
    { "action": "webfetch", "pattern": "*", "effect": "deny" },
    { "action": "webfetch", "pattern": "https://ziglang.org/*", "effect": "allow" },
    // Tools from MCP servers use their tool name as the action.
    { "action": "mcp__github__*", "pattern": "*", "effect": "ask" }
  ]
}
```

Paths are canonical and absolute, so a project-relative file needs a leading `*/`. Put rules in the project's `.zeta/zeta.jsonc` to keep them with the project; arrays replace rather than merge, so a project `permission` list replaces the user's whole list.

## Answering asks

On a TTY, `zeta run` prompts for `allow_once`, `allow_session`, or `deny`. Noninteractive runs deny asks immediately. HTTP clients answer pending requests with `POST /permissions/:id/reply`, body `{"reply":"allow_once"}` (or `allow_session`/`deny`). Unanswered asks expire at the tool deadline, and an ask with no connected `/event` listener is denied at once; a denied tool ends the turn, and `zeta run` then exits with status 1. An `allow_session` reply only answers later asks for the same action and pattern in that session: rules are evaluated first, so a `deny` rule added afterwards still applies.
