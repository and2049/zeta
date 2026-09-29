# Credentials

Use provider `options.apiKey` in [configuration](configuration.md), preferably with `{env:OPENAI_API_KEY}` or `{file:path}` rather than a literal secret. Key resolution is configured `apiKey`, then the local credential store, then models.dev provider environment names, then `<PROVIDER>_API_KEY` (uppercase, hyphens changed to underscores). A local compatible endpoint may need no key.

When using a saved credential, omit `options.apiKey` from config. An explicit config value wins even when its environment substitution expands to an empty string.

`zeta auth login <provider>` reads a hidden terminal key, or one line from piped stdin, and writes an API key into `$XDG_DATA_HOME/zeta/credentials.json` (default `~/.local/share/zeta/credentials.json`). The parent directory is private (0700); the JSON file is private (0600), atomically replaced. `PUT /credentials/:provider` accepts `{"type":"api","key":"..."}`; `GET /credentials` returns provider IDs and credential types (`api`, `oauth`, or `mcp` for an MCP server's sign-in under `mcp:<server>`, or `mcp:<safe>:<hash>` when the name has characters other than letters, digits, `.`, `_` and `-` or is longer than 100) without values. Provider ids cannot contain `:`, so a provider key never replaces a sign-in. API callers still need server Basic auth. Never commit literal keys or include them in shared examples.

OpenAI ChatGPT OAuth can use either a browser callback or a device code. OAuth credentials include
access/refresh tokens and expiry; they are refreshed before model requests.
OpenAI OAuth uses the Codex Responses transport, while API keys use Chat
Completions. See [providers and authentication](providers.md) for supported
providers, login details, and precedence.
