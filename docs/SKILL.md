---
name: zeta
description: Index of zeta's own documentation. Load when the user asks about zeta itself, its config, providers, permissions, tools, skills, hooks, extensions, sessions, protocol, before changing zeta's configuration or resources, or when asked to extend zeta with a new tool, command, hook or provider.
---

# zeta documentation index

The pages below sit next to this file. Find the row for the task, read its first page completely, then the second if needed, and follow links only as far as the task requires. Pages describe how zeta works; the live state (below) shows what is actually loaded right now.

| I want to… | Start here | Then read |
|---|---|---|
| understand how zeta fits together, or where a file lives | `concepts.md` | `README.md` |
| add or change a capability (pick the mechanism, then verify it) | `extending.md` | the page it points to |
| change a setting, model or provider endpoint | `configuration.md` | `examples/zeta.jsonc`, `generated/reference.md` |
| set up a provider, key or sign-in | `providers.md` | `credentials.md` |
| allow, ask about or refuse tool calls | `permissions.md` | `tools.md` |
| add standing instructions or a skill | `skills.md` | `extending.md` |
| add a slash command that expands to a prompt | `commands.md` | |
| run shell commands at hook points | `hooks.md` | `tools.md` (hook points) |
| connect an MCP server | `mcp.md` | `configuration.md` |
| write an extension (tool, command, hook or provider in code) | `extending.md` | `extensions.md`, `examples/extensions/hello/` |
| list, continue, export, undo or move sessions | `sessions.md` | `compaction.md` |
| look up a built-in tool or its limits | `tools.md` | `generated/reference.md` |
| talk to the server over HTTP or read its events | `protocol.md` | `sessions.md` |
| find out why something is not working | `troubleshooting.md` | `concepts.md` (where things live) |

## Checking live state

If enabled with `"inspect_tool": true`, call `zeta_inspect` with no arguments for a summary, then with `section` (`plugins`, `tools`, `hooks`, `providers`, `commands`, `config`, `diagnostics`) for details. Otherwise use `GET /registry` and `GET /config` (`extending.md` shows how to call them); the config view shows which layer set each value before editing a file.

## Changing zeta

Change configuration, skills, prompt templates and `AGENTS.md` with the normal file tools; the next run reads them. Plugins loaded from outside the binary (`hooks.json`, MCP servers, extensions) need `zeta reload` (or `POST /registry/reload`) after a change. Check the result in the registry before telling the user it works. Never modify zeta's own source or binary.
