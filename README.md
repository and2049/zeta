# zeta

A small coding agent in Zig, with no dependencies beyond the standard library.

- One background server per user; the terminal UI, `zeta run` and scripts talk to it over localhost HTTP + SSE.
- Everything in the server is a plugin: tools, providers, hooks, MCP servers, extensions.
- Status: early development.

## Quick start

```sh
zeta                  # full-screen terminal client; /connect to add a provider
zeta run "explain this repo"
```

In the TUI: `/` commands, `@` files, Enter send, Ctrl+J new line, Esc stop, Ctrl+Q quit.

## Configure

`~/.config/zeta/zeta.jsonc`, or `<project>/.zeta/zeta.jsonc`:

```jsonc
{
  "model": "openai/gpt-4.1",
  "provider": {
    "openai": { "options": { "apiKey": "{env:OPENAI_API_KEY}" } },
    // any OpenAI-compatible endpoint
    "local": { "options": { "baseURL": "http://127.0.0.1:8080/v1" } }
  }
}
```

## Commands

```sh
zeta run --json "…"                  # the session's events as JSONL
zeta run --profile local --model local/my-model "…"
zeta run --continue "…"              # continue the project's latest session (-c)
zeta run --session ses_… "…"         # continue a given session
zeta run --standalone "…"            # a private server that ends with the run
git diff | zeta run "review" @notes.md   # stdin and files join the prompt
zeta serve [--hostname 0.0.0.0]      # run the server in the foreground
zeta server stop
zeta sessions [--all] [text]         # list or search; `sessions export <id>` prints JSONL
zeta undo                            # undo the latest reply's file changes
zeta usage [--all | --session <id>]  # tokens and cost
zeta auth login openai
zeta reload                          # reload plugins for this project
```

## Docs

- [Overview](docs/README.md)
- [Configuration](docs/configuration.md), [providers](docs/providers.md), [credentials](docs/credentials.md)
- [Terminal UI](docs/tui.md), [prompt templates](docs/commands.md), [skills](docs/skills.md)
- [Tools](docs/tools.md), [permissions](docs/permissions.md), [hooks](docs/hooks.md)
- [MCP](docs/mcp.md), [extensions](docs/extensions.md), [compaction](docs/compaction.md)
- [HTTP API and events](docs/protocol.md)

## Build

Requires Zig 0.16.0.

```sh
zig build                    # binary at zig-out/bin/zeta
zig build test               # unit tests
zig build docs               # docs and reference at zig-out/docs
cd tests/e2e && bun test     # end-to-end tests (needs bun and a built binary)
```

## License

MIT
