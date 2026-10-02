# Configuration

Put `zeta.jsonc` at `~/.config/zeta/` or `<project>/.zeta/`. JSONC permits comments and trailing commas. For example:

```jsonc
{
  "model": "openai/gpt-4.1",
  "provider": {
    "openai": { "options": { "apiKey": "{env:OPENAI_API_KEY}" } },
    "local": { "options": { "baseURL": "http://127.0.0.1:8080/v1" } }
  },
  "tool_timeout_ms": 120000
}
```

API-key providers use OpenAI-compatible chat completions. Saved OpenAI ChatGPT OAuth credentials select the Codex Responses transport instead. The models.dev catalog supplies endpoints and environment-variable names and is cached at `$XDG_CACHE_HOME/zeta/models.json`; catalog presence does not imply API support. Provider `options` accepts `baseURL`, `apiKey` and `setCacheKey` (send the session id as `prompt_cache_key`; on by default for `openai` only, since some compatible servers reject unknown fields); `models` accepts model metadata overrides, plus `thinkingLevels` and `thinking` per model. The top-level `thinking` key is the default thinking level (see [providers](providers.md#thinking-level)). Strings support `{env:VAR}` and `{file:path}`; relative files resolve next to the config file. See [providers and authentication](providers.md) for `/connect` and credential precedence.

Only officially supported provider metadata is retained from models.dev.
Custom endpoints declare their models under `provider.<id>.models`; these
definitions are not matched automatically against the public catalog. Explicit
custom `baseURL` endpoints may omit an API key and still appear in `/model`.

Precedence (low to high): defaults, user config, project config, user profile, project profile, CLI, environment. Objects merge by key; scalars and arrays replace. Profiles are `profiles/<name>.jsonc` under the user config or project `.zeta/` directory. `--profile`/`ZETA_PROFILE` and `--model`/`ZETA_MODEL` select overrides; environment wins.

When no layer sets `model`, a new session uses the model last picked in any session (`/model`, or `PATCH /sessions/:id`), remembered in `$XDG_STATE_HOME/zeta/model.json` (`~/.local/state/zeta/model.json`); with nothing remembered, the first model of the first connected provider. `thinking` falls back to the last picked level the same way. Provenance shows these as `remembered` and `fallback`. A session keeps the model and thinking level it first ran with, so resuming it continues on them until you pick another; changing `model` in config affects new sessions.

`compaction` (`enabled`, `reserveTokens`, `keepRecentTokens`) controls how long sessions are summarized; see [compaction](compaction.md). MCP servers are configured under `mcp`; see [MCP servers](mcp.md). `extensions` lists extension commands to run for the project, `[{"command": ["…"], "env"?: {…}}]`; see [extensions](extensions.md).

`inspect_tool` defaults to `false`. Set it to `true` in user, project, or profile config to offer `zeta_inspect` to the model. The `/registry` and `/config` HTTP routes work either way. `webfetch` remains enabled by default.

Plugins take their own settings under `plugin.<id>`, where `<id>` is a plugin listed by `GET /registry`:

```jsonc
{ "plugin": { "my-plugin": { "level": 2 } } }
```

A plugin may declare a JSON Schema for its settings; a value that fails it stops runs with `InvalidPluginConfig` until fixed. Settings for a plugin that isn't loaded, and top-level keys zeta doesn't recognize, are kept but ignored: runs log a warning and `GET /config` lists them under `diagnostics`.

See a copyable [example](examples/zeta.jsonc) and the [generated field list](generated/reference.md). zeta has no permission settings of its own; [permissions](permissions.md) shows how a plugin adds them.

`GET /config?location=<absolute-project>` (or `?session=<id>`) returns effective configuration and source layers, with secrets redacted. `PATCH /config` edits *one layer* using `{"target":"user","patch":{"tool_timeout_ms":120000}}` or `{"target":"project","location":"/absolute/project","patch":{...}}`. A target is mandatory; project updates require `location`. The patch recursively merges objects, replaces arrays, and removes an override when its value is `null` (revealing a lower layer on next load). Recognized core fields and extension commands and environment values are validated before atomic replacement; `plugin.<id>` entries are checked against the schema that plugin declares, `mcp` must be an object (with an object `servers`), and other unrecognized top-level keys are rejected. MCP server settings are checked separately when loaded, with invalid settings reported as diagnostics. A successful patch rewrites the JSONC file as formatted JSON and **does not preserve comments or original formatting**; unrelated values remain. Active runs keep their config snapshots; new runs reload config.
