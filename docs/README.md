# zeta documentation

zeta is a Zig coding agent with a localhost server. Build with Zig 0.16.0: `zig build`; run `zig-out/bin/zeta serve` for a foreground server. `zeta serve --hostname <address>` listens on an IPv4 address other than `127.0.0.1` (e.g. `0.0.0.0`), so other machines can connect with HTTP Basic auth (user `zeta`, the password in the discovery file `$XDG_RUNTIME_DIR/zeta/server.json`); plain HTTP, so use it only on networks you trust.

Documentation for configuring and using zeta:

- [Sessions](sessions.md): storage, listing, export, undo, moving and forking
- [Configuration](configuration.md); copyable [config example](examples/zeta.jsonc)
- [Compaction](compaction.md): how long sessions are summarized to fit the context window, and manual compaction
- [HTTP protocol](protocol.md)

The repository's top-level README covers build commands. `zig build docs` installs the documentation tree to `zig-out/docs`. `GET /registry` shows the live plugins, tools, providers and prompt sections a run gets.
