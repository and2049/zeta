# zeta

A small coding agent in Zig, with no dependencies beyond the standard library.

- Extensible agent core with plugins for tools, providers and hooks.
- Status: early development.

## Configure

`~/.config/zeta/zeta.jsonc`, or `<project>/.zeta/zeta.jsonc`:

```jsonc
{
  "model": "example/model",
  "provider": {
    "example": { "options": { "baseURL": "https://example.invalid/v1", "apiKey": "{env:MODEL_API_KEY}" } }
  }
}
```

## Commands

```sh
zeta --version                        # print version
```

## Docs

- [Overview](docs/README.md)
- [Configuration](docs/configuration.md)
- [compaction](docs/compaction.md)

## Build

Requires Zig 0.16.0.

```sh
zig build                    # binary at zig-out/bin/zeta
zig build test               # unit tests
zig build docs               # docs at zig-out/docs
```

## License

MIT
