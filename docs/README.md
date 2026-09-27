# zeta documentation

zeta is a Zig coding agent core. Build with Zig 0.16.0: `zig build`.

Documentation for configuring and using zeta:

- [Sessions](sessions.md): storage, undo, moving and forking
- [Configuration](configuration.md); copyable [config example](examples/zeta.jsonc)
- [Compaction](compaction.md): how long sessions are summarized to fit the context window

The repository's top-level README covers build commands. `zig build docs` installs the documentation tree to `zig-out/docs`.
