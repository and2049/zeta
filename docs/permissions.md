# Permissions

zeta has no built-in permission system: every tool call runs without asking. Approval is a plugin's job. A plugin's `tool_pre` hook sees each call before it runs and can let it through, rewrite its arguments, block it (the model gets the reason and goes on), or deny it (the turn ends). A hook can ask the user first: it puts a question to whichever client is attached and waits for the answer.

## A ready-made policy

`examples/extensions/permissions/` in these docs is a complete permission extension using only the Python standard library. To use it, copy the directory into `~/.config/zeta/extensions/` (or a project's `.zeta/extensions/`) and run `zeta reload`. Its settings go under `plugin.permissions` in `zeta.jsonc`:

```jsonc
{
  "plugin": {
    "permissions": {
      // Files outside the project: "ask" (the default), "allow" or "deny".
      "outside": "ask",
      // Checked in order, the last match wins; no match allows.
      "rules": [
        { "tool": "bash", "pattern": "*", "effect": "ask" },
        { "tool": "bash", "pattern": "git status*", "effect": "allow" },
        { "tool": "write", "pattern": "*/.env", "effect": "deny" },
        { "tool": "mcp__github__*", "pattern": "*", "effect": "ask" }
      ]
    }
  }
}
```

`tool` and `pattern` are shell-style wildcards (`*` also matches `/`). The pattern is matched against the absolute file path (symlinks resolved) for `read`, `write` and `edit`, the command for `bash`, the URL for `webfetch`, and the arguments as JSON for other tools. Paths outside the project are checked for `read`, `write` and `edit`, and for words of a `bash` command that look like paths; that bash check is a best effort, not a sandbox. Each question offers "Allow once", "Allow for this session" (the same tool and pattern stop asking in that session) and "Deny" (the turn ends). Change it freely: it is an ordinary extension ([extensions](extensions.md)).

## Without writing code

A `PreToolUse` [command hook](hooks.md) can refuse calls (exit 2, or `permissionDecision: "deny"`), or ask the user: `{"hookSpecificOutput": {"permissionDecision": "ask", "permissionDecisionReason": "Delete files?"}}` puts a yes/no question to the user, and anything but yes denies the call and ends the turn.

```json
{"hooks": {"PreToolUse": [{"matcher": "bash", "hooks": [{"type": "command",
  "command": "grep -q '\"rm ' && echo '{\"hookSpecificOutput\":{\"permissionDecision\":\"ask\"}}' || true"}]}]}}
```

## Questions

Plugins ask four kinds of question: `confirm` (yes or no, with an optional `detail` such as the call), `select` (one of several `options`), `input` (a line of text, optionally `secret`) and `form` (a JSON Schema object of simple properties; MCP servers' questions are forms). The terminal client shows them above the editor; `zeta run` asks on its terminal and declines without one. An unanswered question declines when its time runs out, when no client is connected, or when the last one leaves; one that is no longer wanted (its call ended) is withdrawn. See [extensions](extensions.md#calls) for asking from an extension and [protocol](protocol.md) for the events and the reply route.
