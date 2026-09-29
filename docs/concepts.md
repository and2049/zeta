# Concepts

The few ideas the rest of these pages build on, and a map of where each thing lives and how to look at it.

## The pieces

- **Server.** One long-lived process per user (`zeta serve`, or started on demand by any client) owns everything: sessions, plugins, credentials, model calls and tools. It listens on localhost and writes a discovery file (`$XDG_RUNTIME_DIR/zeta/server.json`) with its URL and password. `zeta run --standalone` start a private server instead.
- **Clients.** `zeta run`, the other CLI commands and any script are clients of the same [HTTP API and event stream](protocol.md). Clients hold no agent logic; two clients on one session see the same thing.
- **Project (location).** The nearest enclosing git root of a directory, or the directory itself. Sessions, project config, project plugins and permissions are all per project. HTTP routes take it as `location=<absolute path>` or derive it from `session=<id>`.
- **Session.** A conversation in one project, stored as an append-only JSONL log. A session pins its model and thinking level on its first run. See [sessions](sessions.md).
- **Run and turn.** A run starts when a prompt leaves the session's inbox and ends when the agent stops; each model request and the tool calls it makes form a turn. Inputs wait in the inbox and are delivered one at a time.
- **Plugins.** Every capability is a plugin in one registry: each built-in tool, each provider, each wire API (OpenAI Chat Completions, Codex Responses, Anthropic Messages), the skills loader, each `hooks.json` file, each MCP server and each extension. `GET /registry` lists them with what each one provides.
- **Layers.** Plugins and config come from three layers: built-in (inside the binary), user (`~/.config/zeta/`, `~/.agents/`) and project (`<project>/.zeta/`, `<project>/.agents/`). A narrower layer wins: a project tool replaces a user or built-in tool of the same name, and project config overrides user config. Hooks from every layer run, built-in first.
- **Resources.** Plain files read fresh for every run, with no code: `zeta.jsonc`, `AGENTS.md`, skills and prompt templates.

## What zeta can change about itself

zeta changes its own behavior through files, never through its source or binary:

| To change | Edit | Takes effect |
|---|---|---|
| settings, model, providers, permissions | `zeta.jsonc` ([configuration](configuration.md)) | next run |
| standing instructions | `AGENTS.md` ([skills](skills.md)) | next run |
| on-demand know-how | `skills/<name>/SKILL.md` ([skills](skills.md)) | next run |
| slash commands that expand to a prompt | `prompts/<name>.md` ([prompt templates](commands.md)) | immediately |
| shell commands at hook points | `hooks.json` ([command hooks](hooks.md)) | `zeta reload` |
| tools from an MCP server | `mcp` in `zeta.jsonc` ([MCP servers](mcp.md)) | `zeta reload` |
| new tools, commands, hooks or providers in code | an extension ([extensions](extensions.md)) | `zeta reload` |

[Extending zeta](extending.md) explains how to pick between them and how to check the result.

## Where things live

`<config>` is `$XDG_CONFIG_HOME/zeta` (default `~/.config/zeta`), `<data>` is `$XDG_DATA_HOME/zeta` (`~/.local/share/zeta`), `<state>` is `$XDG_STATE_HOME/zeta` (`~/.local/state/zeta`), `<cache>` is `$XDG_CACHE_HOME/zeta` (`~/.cache/zeta`), and `<runtime>` is `$XDG_RUNTIME_DIR/zeta` (on macOS, or without that variable, `<state>`). Relative XDG values are ignored.

| What | User | Project | Inspect with |
|---|---|---|---|
| config | `<config>/zeta.jsonc`, `<config>/profiles/<name>.jsonc` | `.zeta/zeta.jsonc`, `.zeta/profiles/<name>.jsonc` | `GET /config`, `zeta_inspect` `config` |
| instructions | `<config>/AGENTS.md` | `AGENTS.md` in the project and every ancestor directory | `GET /registry` `prompt_sections` |
| skills | `~/.agents/skills/`, `<config>/skills/` | `.agents/skills/`, `.zeta/skills/` | `GET /registry` `skills` |
| prompt templates | `~/.agents/prompts/`, `<config>/prompts/` | `.agents/prompts/`, `.zeta/prompts/` | `GET /commands` |
| command hooks | `~/.agents/hooks.json`, `<config>/hooks.json` | `.agents/hooks.json`, `.zeta/hooks.json` | `GET /registry` `hooks` |
| extensions | `~/.agents/extensions/`, `<config>/extensions/` | `.agents/extensions/`, `.zeta/extensions/`, `extensions` in config | `GET /extensions`, `zeta_inspect` `plugins` |
| MCP servers | `mcp` in user config | `mcp` in project config | `zeta mcp`, `GET /mcp` |
| sessions | `<data>/sessions/<project-hash>/<id>.jsonl`, saved tool output in `<id>.artifacts/` | | `zeta sessions`, `GET /sessions` |
| credentials | `<data>/credentials.json` (0600) | | `GET /credentials` (no values) |
| these docs | `<data>/docs/<content-hash>/` | | the `zeta` skill |
| last picked model | `<state>/model.json` | | `GET /config` provenance `remembered` |
| server log | `<state>/server.log` for a server a client started (emptied when it starts); `zeta serve` logs to its terminal | | read the file |
| extension logs | `<state>/extensions/<name>.log` | | read the file |
| model catalog cache | `<cache>/models.json` | | `GET /models` |
| discovery file | `<runtime>/server.json` (0600) | | `GET /health` |

Project paths are relative to the project root. Where a cell lists several places, later ones win when names collide (skills, templates); `AGENTS.md` and `hooks.json` files all apply, in the order listed.

## Environment variables

| Variable | Effect |
|---|---|
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_RUNTIME_DIR` | move the directories above |
| `ZETA_PROFILE` | select a profile; overrides `--profile` |
| `ZETA_MODEL` | select a model; overrides `--model` and config |
| `<PROVIDER>_API_KEY` and the catalog's names (`OPENAI_API_KEY`, …) | provider keys, after config and saved credentials ([credentials](credentials.md)) |

Hook commands receive `ZETA_PROJECT_DIR` and `ZETA_SESSION_ID` ([command hooks](hooks.md#input)). Use `{env:VAR}` in any config string to read others.
