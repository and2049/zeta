//! XDG base directories for zeta. All paths end in `/zeta`.

const std = @import("std");

pub const Paths = struct {
    /// `$XDG_CONFIG_HOME/zeta`: user config.
    config: []const u8,
    /// `$XDG_DATA_HOME/zeta`: sessions.
    data: []const u8,
    /// `$XDG_STATE_HOME/zeta`: remembered model selection.
    state: []const u8,

    /// Strings are allocated in `arena` and live as long as it does.
    pub fn resolve(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !Paths {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        const state = try dir(arena, env, "XDG_STATE_HOME", home, ".local/state");
        return .{
            .config = try dir(arena, env, "XDG_CONFIG_HOME", home, ".config"),
            .data = try dir(arena, env, "XDG_DATA_HOME", home, ".local/share"),
            .state = state,
        };
    }
};

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
}

test "XDG overrides, relative values ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/h");
    try env.put("XDG_DATA_HOME", "/d");
    try env.put("XDG_CONFIG_HOME", "rel");
    const p = try Paths.resolve(arena.allocator(), &env);
    try std.testing.expectEqualStrings("/d/zeta", p.data);
    try std.testing.expectEqualStrings("/h/.config/zeta", p.config);
}
