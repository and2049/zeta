# zeta documentation

zeta is a Zig coding agent with a localhost server and clients. Build with Zig 0.16.0: `zig build`; run `zig-out/bin/zeta run "question"` for headless use, or `zig-out/bin/zeta serve` for a foreground server. `zeta run` sends text piped on stdin first, then each `@file` argument (a text file's contents in a `<file name="…">` block; a PNG, JPEG, GIF or WebP as an image attachment with an empty block naming it; at most 4 MiB each), then the prompt words. `zeta run --continue` (`-c`) prompts the project's latest session instead of a new one, and `--session <id>` a given one; `--model` and `--thinking` then change that session's selection. `zeta run` exits 0 only when the run ends with a final reply; an error, an abort, or a denied tool exits 1. If its event stream drops, it reconnects to the running server (without starting one) for up to 10 seconds and prints what it missed.

Clients share one background server per user, started on demand. `zeta run --standalone` starts a private server instead: it keeps its discovery record, lock and log in a directory of its own, loads none of the sessions saved earlier (its own are saved as usual; a session a server has open is locked, so another server never loads it at the same time), and stops when the client ends, removing its directory. `zeta serve --hostname <address>` listens on an IPv4 address other than `127.0.0.1` (e.g. `0.0.0.0`), so other machines can connect with HTTP Basic auth (user `zeta`, the password in the discovery file `$XDG_RUNTIME_DIR/zeta/server.json`); plain HTTP, so use it only on networks you trust.

These documents ship inside the binary and are extracted to the user data directory under `docs/<content-hash>/`. Read the relevant page before changing configuration or resources:

- [Concepts](concepts.md): the server, clients, projects, plugins and layers, where every file lives, and environment variables
- [Extending zeta](extending.md): choosing between config, instructions, skills, templates and hooks, and checking a change took
- [Sessions](sessions.md): storage, listing, export, undo, moving and forking
- [Troubleshooting](troubleshooting.md): diagnostics, logs and common problems
- [Configuration](configuration.md) and [credentials](credentials.md); copyable [config example](examples/zeta.jsonc)
- [Supported providers and authentication](providers.md)
- [Tools](tools.md), [permissions](permissions.md), and [skills](skills.md)
- [Prompt templates](commands.md): slash commands from `prompts/*.md`
- [Compaction](compaction.md): how long sessions are summarized to fit the context window, and manual compaction
- [Command hooks](hooks.md): shell commands from `hooks.json` at session start, prompt submit, tool calls, permission asks and stop
- [HTTP protocol](protocol.md)
- [Generated tool/config reference](generated/reference.md) (`zig build docs` writes the complete documentation tree to `zig-out/docs`)

The repository's top-level README covers the CLI and build commands. Self-docs do not authorize modifying zeta's source or binary. The built-in `zeta` skill indexes these pages, and `GET /registry` shows the live plugins, tools, providers and prompt sections a run gets. The optional `zeta_inspect` tool provides this view when `inspect_tool` is enabled.
