# Troubleshooting

Start with what zeta reports about itself, then the logs.

## Where to look

1. **Registry diagnostics.** `GET /registry?location=<project>` (or `zeta_inspect` `diagnostics`) lists load failures and warnings for plugins: a `hooks.json` that does not parse, a skipped hook matcher, an MCP server or extension that failed. A plugin that failed to reload keeps its previous version until fixed.
2. **Config diagnostics.** `GET /config?location=<project>` shows each effective value with the layer that set it, and lists ignored keys and invalid `plugin.<id>` settings.
3. **Extension and MCP status.** `GET /extensions` and `GET /mcp` (`zeta mcp`, `/extensions` and `/mcp` in the terminal client) give each one's status and last error.
4. **Server log.** A server started by a client writes to `$XDG_STATE_HOME/zeta/server.log` (default `~/.local/state/zeta/server.log`), emptied each time one starts; `zeta serve` writes to its terminal instead. It has provider failures, retries, hook and extension failures, skipped skills and catalog refresh errors.
5. **Extension logs.** `$XDG_STATE_HOME/zeta/extensions/<name>.log`, an extension's stderr, emptied on each start.
6. **The session log.** The `system` lines in a session's JSONL show exactly what the model was told, and message lines what it did ([sessions](sessions.md)).

A `--standalone` server keeps its logs in its own private directory, removed when it stops.

## Common problems

| Symptom | Likely cause | Fix |
|---|---|---|
| A change to config, `AGENTS.md`, a skill or a template does not show | the run started before the change | send the next prompt; these are read per run |
| A changed `hooks.json`, MCP server or extension does not show | not reloaded, or the reload failed (`zeta reload` exits 1 and names the plugin) | fix it, `zeta reload`, then check diagnostics |
| A rebuilt or upgraded `zeta` behaves like the old one | the shared server is still the old binary | `zeta server stop`; the next client starts the new one |
| Extension `failed`: no register | it printed nothing, crashed, or took over 10 seconds | run its command by hand; read its log |
| Extension `failed`: protocol error | something other than one JSON object per line on stdout | send logs to stderr; flush after each message |
| Extension `failed` after a while | it stopped answering pings for 30 seconds | read stdin on a thread of its own; handle requests concurrently |
| Extension `failed`: `registered as 'x', expected 'y'` | `register` used a different name from the manifest or file | make them equal |
| Runs stop with `InvalidPluginConfig` | `plugin.<id>` fails the schema that plugin declared | fix the value; `GET /config` names it |
| A model is missing from `/model` | its provider has no key, saved credential or configured endpoint | `/connect`, `zeta auth login <provider>`, or `provider.<id>.options` |
| A tool call is denied and the run ends | a plugin asked the user with nobody to answer (`zeta run` without a terminal declines), or the user denied it | change that plugin's settings, e.g. an `allow` rule ([permissions](permissions.md)) |
| A tool call is blocked but the run goes on | a hook blocked it; the reason is in the tool result | check the hooks in the registry |
| A skill is not listed | file not named `SKILL.md`, not in its own directory under a skills root, bad frontmatter, or an invalid name | see [skills](skills.md) |
| A prompt template is not offered | a client command name, whitespace in the name, or in a subdirectory | see [prompt templates](commands.md) |

## Starting clean

- `zeta server stop` stops the shared server (sessions are saved as they go).
- `zeta --standalone` or `zeta run --standalone` runs with a private server that loads none of the earlier sessions, useful for checking whether a problem comes from server state.
- The model catalog (`$XDG_CACHE_HOME/zeta/models.json`) is refreshed in the background each time a server starts; a failed refresh keeps the cached copy and logs `model catalog refresh failed` with the reason.
