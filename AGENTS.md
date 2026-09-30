# AGENTS.md

Rules for anyone (human or agent) changing zeta.

## Before you finish

- `zig fmt src build.zig`
- `zig build test`
- `zig build` and run the fresh binary for anything user-visible.
- E2E: `bun test` in `tests/e2e/` when the server, client, or loop changes.

## Code

- Zig 0.16.0, standard library only. No dependencies.
- `src/main.zig` is the composition root: parse argv, pick a role, wire modules. No leaf logic.
- Module boundaries are enforced by `build.zig` imports:
  - `proto`, `platform`: std only.
  - `plugin`: proto.
  - `core`: proto, plugin. Never builtins, server, client, or tui.
  - `builtins`: plugin, core, platform, proto.
  - `server`: proto, plugin, core, platform.
  - `client`: proto, platform.
  - `tui`: client, proto, platform. Never core.
- Files stay under about 400 lines.
- Explicit allocators and documented ownership. Prefer arenas scoped to a turn or request.
- Tests live in the same file, using `std.testing.allocator` and `std.testing.io`.

## Commits

- Title: `type(scope): summary`. Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`.
- Scopes: `core`, `plugin`, `proto`, `platform`, `builtins`, `server`, `client`, `tui`, `build`, `docs`, `e2e`.
- Body: plain, at most 4 lines.
