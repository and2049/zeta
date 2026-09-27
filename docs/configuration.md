# Configuration

Put `zeta.jsonc` at `~/.config/zeta/` or `<project>/.zeta/`. JSONC permits comments and trailing commas. For example:

```jsonc
{
  "model": "example/model",
  "provider": {
    "example": { "options": { "baseURL": "https://example.invalid/v1", "apiKey": "{env:MODEL_API_KEY}" } }
  },
  "tool_timeout_ms": 120000
}
```

Provider `options` accepts `baseURL`, `apiKey` and `setCacheKey` (whether a provider sends the session id as a prompt-cache key); `models` accepts model metadata overrides, plus `thinkingLevels` and `thinking` per model. The top-level `thinking` key is the default thinking level. Strings support `{env:VAR}` and `{file:path}`; relative files resolve next to the config file. No providers are registered by default; provider plugins can supply model routes.

Provider model overrides go under `provider.<id>.models`.

Precedence (low to high): defaults, user config, project config, user profile, project profile, environment. Objects merge by key; scalars and arrays replace. Profiles are `profiles/<name>.jsonc` under the user config or project `.zeta/` directory. Session creation selects profiles and models; environment overrides can be supplied there.

When no layer sets `model`, a new session uses the model last picked in any session, remembered in `$XDG_STATE_HOME/zeta/model.json` (`~/.local/state/zeta/model.json`); with nothing remembered, the first model of the first connected provider. `thinking` falls back to the last picked level the same way. Provenance shows these as `remembered` and `fallback`. A session keeps the model and thinking level it first ran with, so resuming it continues on them until you pick another; changing `model` in config affects new sessions.

`compaction` (`enabled`, `reserveTokens`, `keepRecentTokens`) controls how long sessions are summarized; see [compaction](compaction.md).

Plugins take their own settings under `plugin.<id>`:

```jsonc
{ "plugin": { "my-plugin": { "level": 2 } } }
```

A plugin may declare a JSON Schema for its settings; a value that fails it stops runs with `InvalidPluginConfig` until fixed. Settings for a plugin that isn't loaded, and top-level keys zeta doesn't recognize, are kept but ignored: runs log a warning and report them under `diagnostics`.

The `permission` array contains ordered rules with `action`, `pattern` and `effect` (`allow`, `deny`, or `ask`). The last matching rule wins; without a match, calls are allowed. See the copyable [example](examples/zeta.jsonc).

Configuration edits change one user or project layer at a time. A patch recursively merges objects, replaces arrays, and removes an override when its value is `null` (revealing a lower layer on next load). Recognized core fields are validated before atomic replacement; `plugin.<id>` entries are checked against the schema that plugin declares, and unrecognized top-level keys are rejected. A successful edit rewrites the JSONC file as formatted JSON and **does not preserve comments or original formatting**; unrelated values remain. Active runs keep their config snapshots; new runs reload config.
