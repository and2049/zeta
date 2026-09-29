# Extending zeta

How to add a capability to zeta, or change how it behaves, and check that the change took. Read [concepts](concepts.md) first for the terms used here.

## Ground rules

- Change zeta through files: config, `AGENTS.md`, skills, prompt templates, `hooks.json` and MCP servers. Never edit zeta's source or replace its binary.
- Prefer the smallest mechanism that does the job: a line in `AGENTS.md` before a skill, a skill before a hook, and a hook before an MCP server.
- Put a change in the project layer (`<project>/.zeta/`) when it only matters to that project, and in the user layer (`~/.config/zeta/`) when it should follow the user everywhere. Ask the user when it isn't clear.
- Look before writing: check the live state (below) for a plugin, tool, command or setting that already does it, or that the change would replace.
- Never put a secret in a file. Use `{env:VAR}` or `{file:path}` in config, and `zeta auth login <provider>` for provider keys.

## Pick a mechanism

| The user wants… | Use | Page |
|---|---|---|
| zeta to always follow a rule ("run `zig fmt` before committing") | a line in `AGENTS.md` | [skills](skills.md#instructions) |
| knowledge or a procedure the model loads only when relevant | a skill | [skills](skills.md) |
| a reusable prompt behind `/name` | a prompt template | [prompt templates](commands.md) |
| a different model, provider endpoint, timeout or other setting | `zeta.jsonc` | [configuration](configuration.md) |
| some tool calls allowed, asked about or refused | `permission` rules | [permissions](permissions.md) |
| a shell command run when a session starts, a prompt is sent, around tool calls, at a permission question, or when the agent stops | a command hook | [command hooks](hooks.md) |
| tools from an existing MCP server | `mcp` in `zeta.jsonc` | [MCP servers](mcp.md) |
| a model on an OpenAI-compatible endpoint | `provider.<id>` in config | [providers](providers.md) |

## Look at the live state

With `"inspect_tool": true` in config, the model has `zeta_inspect`: call it with no arguments for a summary, then with a `section` (`plugins`, `tools`, `hooks`, `providers`, `commands`, `config`, `diagnostics`).

Without it, ask the server directly. The discovery file holds its URL and password:

```sh
d="${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/zeta}"; d="${d:-${XDG_STATE_HOME:-$HOME/.local/state}/zeta}/server.json"
url=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$d")
pw=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["password"])' "$d")
curl -su "zeta:$pw" "$url/registry?location=$PWD"     # plugins, tools, hooks, providers, skills, diagnostics
curl -su "zeta:$pw" "$url/config?location=$PWD"       # effective config and which layer set each value
```

(On macOS there is no `$XDG_RUNTIME_DIR`; the file is under the state directory.) `location` is any absolute directory in the project; the server uses its git root. `prompt_sections` in the registry names the parts of the system prompt, including each `AGENTS.md` file. On the command line, `zeta reload` reports plugins that failed to load (and exits 1), and `zeta mcp` lists MCP servers.

## The loop

1. Write or edit the file.
2. If it is a `hooks.json` or an MCP server, run `zeta reload` (or `POST /registry/reload`); it exits 1 and names any plugin that failed to load. Everything else is read on the next run.
3. Check that it loaded: the registry lists the new plugin, tool, hook or command, and `diagnostics` is empty. A plugin that fails to reload keeps its previous version and reports why in `diagnostics`.
4. Try it: `zeta run "use word_count on 'a b c'"`, or run the command over HTTP. `zeta run` exits 1 when the run fails or a tool is denied.
5. If something is wrong, read the logs ([troubleshooting](troubleshooting.md)).

A run already in progress keeps the plugins it started with, so the change shows from the next run on.

## Recipes

- **Block a dangerous command** without code: a `PreToolUse` hook on `bash` that exits 2 with a reason on stderr ([command hooks](hooks.md)), or a `deny` rule with a pattern ([permissions](permissions.md)).
- **Add project context at the start of every session:** a line in the project's `AGENTS.md`; for context computed at the time, a `SessionStart` hook printing `{"additionalContext": "…"}`.
- **A `/review` command:** `.zeta/prompts/review.md` with `$1` for the path ([prompt templates](commands.md)).
- **A team procedure the model should follow when relevant:** `.zeta/skills/<name>/SKILL.md` with a description that says when to use it ([skills](skills.md)).
- **A local model server:** `provider.local.options.baseURL` plus its models under `provider.local.models` ([providers](providers.md)).
