# zeta

A small coding agent in Zig, with no dependencies beyond the standard library.

- One foreground server per user; HTTP clients talk to it over localhost HTTP + SSE.
- Everything in the server is a plugin: tools, providers, hooks.
- Status: early development.

## Quick start

```sh
zeta serve
```

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
zeta serve [--hostname 0.0.0.0]      # run the server in the foreground
```

## Docs

- [Overview](docs/README.md)
- [Configuration](docs/configuration.md), [providers](docs/providers.md), [credentials](docs/credentials.md)
- [compaction](docs/compaction.md)
- [HTTP API and events](docs/protocol.md)

## Build

Requires Zig 0.16.0.

```sh
zig build                    # binary at zig-out/bin/zeta
zig build test               # unit tests
zig build docs               # docs at zig-out/docs
cd tests/e2e && bun test     # end-to-end tests (needs bun and a built binary)
```

## License

MIT
