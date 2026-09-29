# Command hooks

A command hook is a shell command zeta runs at a point in a run: when a session starts, when a prompt is submitted, before and after a tool call, when permission rules would ask, and when the agent would stop. Hooks can add context for the model, block a prompt or a tool call, answer a permission question, or keep the agent going. The file format follows the widely used `hooks.json` layout, so many existing hook scripts work unchanged.

## Files

zeta reads every `hooks.json` it finds, in this order:

1. `~/.agents/hooks.json`
2. `~/.config/zeta/hooks.json` (the zeta config directory)
3. `<project>/.agents/hooks.json`
4. `<project>/.zeta/hooks.json`

All of them run; a later file runs after an earlier one. Each file is a plugin (id `hooks:<path>`) in the user or project layer, listed by `GET /registry` and `zeta_inspect`. User files are read when the server first needs them and project files when the project is first used; after editing one, run `zeta reload` (or `POST /registry/reload`). A file that no longer parses keeps its previous version and the error shows in the registry's `diagnostics`; a deleted file stops running on reload. Project hooks run without a trust prompt, like the rest of the project's configuration.

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/bin/check-command.sh", "timeout": 10 }] }
    ],
    "SessionStart": [
      { "matcher": "startup", "hooks": [{ "type": "command", "command": "echo '{\"additionalContext\": \"Run tests with zig build test.\"}'" }] }
    ]
  }
}
```

Comments and trailing commas are allowed. Only `"type": "command"` hooks run; other types and unknown events are skipped with a diagnostic. `timeout` is in seconds (default 60). The command runs with `/bin/sh -c` in the project directory, one hook at a time, with stdout and stderr each capped at 32 KiB.

## Matchers

`matcher` selects which tools (or, for `SessionStart`, which source) a group applies to. Empty or `*` matches everything. Otherwise it is a list of names separated by `|`, each of which may use `*` (any run of characters) and `?` (one character). Tool names are zeta's (`bash`, `read`, `write`, `edit`, `webfetch`, `skill`, and plugin tools) and also match their capitalised aliases (`Bash`, `Read`, `Write`, `Edit`, `WebFetch`, `Skill`). Regular expressions are not supported: a matcher containing `.`, `^`, `$`, brackets, braces, `+` or `\` is skipped with a diagnostic. `UserPromptSubmit` and `Stop` ignore the matcher.

## Events

| Event | When | What a hook can do |
|---|---|---|
| `SessionStart` | when a session's first run in this server process starts, before any prompt hook; `source` is `startup` (new session) or `resume` (history from before a restart) | add context |
| `UserPromptSubmit` | when a prompt leaves the inbox, before it joins the conversation | block it, or add context |
| `PreToolUse` | after the arguments pass the tool's schema, before permissions | block the call, or replace its arguments |
| `PermissionRequest` | when permission rules would ask the user (never for an explicit `deny` rule, never when a rule allows) | allow (optionally with new arguments), deny with a reason, or leave it to the user |
| `PostToolUse` | after a tool succeeds | add text to the result the model sees |
| `PostToolUseFailure` | after a tool fails (an error result or an error the tool raised) | add text to the result |
| `Stop` | when the agent would stop | keep going with a reason as the next user message (once in a row) |

Context from `SessionStart` and `UserPromptSubmit` is added to the conversation as a user message marked `"origin": "hook"`: `SessionStart` context before anything else in that run, `UserPromptSubmit` context right after its prompt. The model sees it; clients can show it differently. A `Stop` continuation is also marked `"origin": "hook"`. A blocked prompt is removed from the inbox and never reaches the model; clients get a `prompt.blocked` event with `{inboxId, reason}`, and `zeta run` exits 1 printing the reason. A blocked or denied tool call gets the reason as its error result and the turn goes on; this differs from a user denying a permission, which ends the turn.

## Input

The hook gets one JSON object on stdin. Fields appear in camelCase and, for compatibility, snake_case:

- Always: `hookEventName`/`hook_event_name`, `sessionId`/`session_id`, `cwd` (the project), `transcriptPath`/`transcript_path` (the session's JSONL log), `provider`, `model`.
- Tool events: `toolName`/`tool_name`, `toolInput`/`tool_input` (the arguments, unchanged), `toolCallId`/`tool_use_id`.
- `PermissionRequest`: also `action` and `pattern`, the permission request the rules would ask about.
- `PostToolUse`, `PostToolUseFailure`: `toolResponse`/`tool_response` as `{text, isError}`; the failure event also has `error`.
- `UserPromptSubmit`: `prompt`. `SessionStart`: `source`. `Stop`: `lastAssistantMessage`/`last_assistant_message` and `stopHookActive`/`stop_hook_active` (true when a hook already continued the previous stop).

The environment adds `ZETA_PROJECT_DIR`, `ZETA_SESSION_ID` and `CLAUDE_PROJECT_DIR` (the project directory) to the server's own.

## Output

- **Exit 2** blocks: stderr is the reason. For `PreToolUse` the call is blocked; `PermissionRequest` denies; `UserPromptSubmit` blocks the prompt; `Stop` keeps going with the reason; `PostToolUse` adds the reason to the result; `SessionStart` ignores it.
- **Exit 0** with stdout starting with `{` is read as JSON. Other stdout is ignored.
- **Any other exit**, a timeout, or JSON that does not parse is a failure. A failing `PreToolUse` hook blocks the call and a failing `PermissionRequest` hook denies it; for other events the failure is logged in the server log and the next command runs. The timeout covers the whole command, including any time it keeps running after closing its output.

JSON fields:

- `continue: false` with `stopReason`: block (tool, permission and prompt events).
- `decision: "block"` with `reason`: block (or, for `Stop`, keep going with the reason; for `PostToolUse`, add the reason to the result). `decision: "approve"` allows a `PermissionRequest`.
- `additionalContext` (top level or inside `hookSpecificOutput`): context for `SessionStart` and `UserPromptSubmit`; added to the result for `PostToolUse`.
- `hookSpecificOutput.permissionDecision`: `deny` blocks a `PreToolUse` call with `permissionDecisionReason`; `allow` and `ask` leave permissions to the rules (use `PermissionRequest` to answer them).
- `hookSpecificOutput.updatedInput`: new arguments for `PreToolUse`, checked against the tool's schema again.
- `hookSpecificOutput.decision`: for `PermissionRequest`, `{"behavior": "allow", "updatedInput"?: {…}}` or `{"behavior": "deny", "message": "…"}`. New arguments are checked against the tool's schema and the permission rules again: a `deny` rule (or an `external_directory` deny) still refuses them, while the hook's approval stands for anything that would be asked. A tool that asks again during a call (such as `webfetch` on a redirect) cannot have its arguments rewritten; such an approval counts as a refusal.

Within one file the matching commands for an event run in order and the first block ends the event; across files, hooks follow the plugin order described in [tools](tools.md#hook-points).
