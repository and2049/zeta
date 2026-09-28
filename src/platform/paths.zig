//! XDG base directories for zeta. All paths end in `/zeta`.

const std = @import("std");
const builtin = @import("builtin");

pub const Paths = struct {
    /// `$XDG_CONFIG_HOME/zeta`: user config, skills.
    config: []const u8,
    /// `$XDG_DATA_HOME/zeta`: sessions, credentials, materialized docs.
    data: []const u8,
    /// `$XDG_STATE_HOME/zeta`: server log.
    state: []const u8,
    /// `$XDG_CACHE_HOME/zeta`: models.dev catalog.
    cache: []const u8,
    /// `$XDG_RUNTIME_DIR/zeta`, else the state dir: discovery file.
    runtime: []const u8,

    /// Where an auto-spawned server writes its output.
    pub fn serverLog(p: Paths, arena: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(arena, &.{ p.state, "server.log" });
    }

    /// Strings are allocated in `arena` and live as long as it does.
    pub fn resolve(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !Paths {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        const state = try dir(arena, env, "XDG_STATE_HOME", home, ".local/state");
        return .{
            .config = try dir(arena, env, "XDG_CONFIG_HOME", home, ".config"),
            .data = try dir(arena, env, "XDG_DATA_HOME", home, ".local/share"),
            .state = state,
            .cache = try dir(arena, env, "XDG_CACHE_HOME", home, ".cache"),
            .runtime = if (runtimeBase(env)) |base|
                try std.fs.path.join(arena, &.{ base, "zeta" })
            else
                state,
        };
    }
};

fn runtimeBase(env: *const std.process.Environ.Map) ?[]const u8 {
    if (builtin.os.tag == .macos) return null;
    const v = env.get("XDG_RUNTIME_DIR") orelse return null;
    return if (std.fs.path.isAbsolute(v)) v else null;
}

/// XDG says relative values must be ignored.
fn dir(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    name: []const u8,
    home: []const u8,
    fallback: []const u8,
) ![]const u8 {
    if (env.get(name)) |v| {
        if (std.fs.path.isAbsolute(v)) return std.fs.path.join(arena, &.{ v, "zeta" });
    }
    return std.fs.path.join(arena, &.{ home, fallback, "zeta" });
}

test "defaults under HOME" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/h");
    const p = try Paths.resolve(arena.allocator(), &env);
    try std.testing.expectEqualStrings("/h/.config/zeta", p.config);
    try std.testing.expectEqualStrings("/h/.local/share/zeta", p.data);
    try std.testing.expectEqualStrings("/h/.local/state/zeta", p.state);
    try std.testing.expectEqualStrings("/h/.cache/zeta", p.cache);
    try std.testing.expectEqualStrings("/h/.local/state/zeta", p.runtime);
}

test "XDG overrides, relative values ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/h");
    try env.put("XDG_DATA_HOME", "/d");
    try env.put("XDG_CONFIG_HOME", "rel");
    try env.put("XDG_RUNTIME_DIR", "/run/user/1");
    const p = try Paths.resolve(arena.allocator(), &env);
    try std.testing.expectEqualStrings("/d/zeta", p.data);
    try std.testing.expectEqualStrings("/h/.config/zeta", p.config);
    if (builtin.os.tag != .macos) try std.testing.expectEqualStrings("/run/user/1/zeta", p.runtime);
}
