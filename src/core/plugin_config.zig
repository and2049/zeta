//! Checks `plugin.<id>` config against the registered plugins, and reports
//! config zeta doesn't use. Invalid config for a plugin fails the run;
//! anything unknown is only reported.
const std = @import("std");
const plugin = @import("plugin");
const config = @import("config.zig");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;

pub const Report = struct {
    /// One line each, for the log and `/config`.
    diagnostics: []const []const u8,
    /// Set when some plugin's config fails its declared schema.
    invalid: bool,
};

/// Messages live in `arena`.
pub fn check(arena: Allocator, cfg: config.Config, plugins: []const plugin.Registry.Plugin) !Report {
    var out: std.ArrayList([]const u8) = .empty;
    var invalid = false;
    for (cfg.unknown) |key| try out.append(arena, try std.fmt.allocPrint(arena, "unknown config key \"{s}\" is ignored", .{key}));
    var it = cfg.plugin.map.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        const owner = find(plugins, id) orelse {
            try out.append(arena, try std.fmt.allocPrint(arena, "config for unknown plugin \"{s}\" is ignored", .{id}));
            continue;
        };
        if (try issue(arena, owner, entry.value_ptr.*)) |message| {
            invalid = true;
            try out.append(arena, try std.fmt.allocPrint(arena, "plugin \"{s}\" config: {s}", .{ id, message }));
        }
    }
    return .{ .diagnostics = out.items, .invalid = invalid };
}

/// The first schema issue in `value`, or null when it is valid or the
/// plugin declares no schema.
pub fn issue(arena: Allocator, owner: plugin.Registry.Plugin, value: std.json.Value) !?[]const u8 {
    const text = owner.config_schema orelse return null;
    const declared = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const issues = try schema.validate(arena, declared, value);
    if (issues.len == 0) return null;
    return try std.fmt.allocPrint(arena, "{s}: {s}", .{ issues[0].path, issues[0].message });
}

pub fn find(plugins: []const plugin.Registry.Plugin, id: []const u8) ?plugin.Registry.Plugin {
    var best: ?plugin.Registry.Plugin = null;
    for (plugins) |p| {
        if (!std.mem.eql(u8, p.id, id)) continue;
        if (best == null or @intFromEnum(p.layer) >= @intFromEnum(best.?.layer)) best = p;
    }
    return best;
}

test "narrower plugin schema controls validation and patches" {
    const a = std.testing.allocator;
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const arena = state.allocator();
    const plugins = [_]plugin.Registry.Plugin{
        .{ .id = "lint", .layer = .builtin, .config_schema = "{\"type\":\"object\",\"properties\":{\"level\":{\"type\":\"integer\"}}}" },
        .{ .id = "lint", .layer = .project, .config_schema = "{\"type\":\"object\",\"properties\":{\"level\":{\"type\":\"string\"}}}" },
    };
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"level\":2}", .{});
    var cfg: config.Config = .{};
    try cfg.plugin.map.put(arena, "lint", value);
    const report = try check(arena, cfg, &plugins);
    try std.testing.expect(report.invalid);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const path = try @import("config_edit.zig").pathFor(arena, .user, base, base);
    const patch = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"plugin\":{\"lint\":{\"level\":2}}}", .{});
    try std.testing.expectError(error.InvalidPluginConfig, @import("config_edit.zig").patchFileFor(arena, std.testing.io, path, patch, &plugins));
    const valid = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"plugin\":{\"lint\":{\"level\":\"high\"}}}", .{});
    try @import("config_edit.zig").patchFileFor(arena, std.testing.io, path, valid, &plugins);
}

test "unknown keys and plugins are reported; schema failures mark the config invalid" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = config.file_name, .data =
        \\{ "theme": "dark", "plugin": { "lint": { "level": 3 }, "ghost": {} } }
    });
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const cfg = try config.load(arena, io, &env, base, base);
    try std.testing.expectEqual(@as(usize, 1), cfg.unknown.len);
    try std.testing.expect(cfg.source("theme") == null);
    try std.testing.expectEqual(config.Source.user, cfg.source("plugin.lint.level").?);
    try std.testing.expectEqual(@as(i64, 3), cfg.pluginOptions("lint").?.object.get("level").?.integer);

    const lint_schema =
        \\{"type":"object","properties":{"level":{"type":"string"}}}
    ;
    const plugins = [_]plugin.Registry.Plugin{.{ .id = "lint", .config_schema = lint_schema }};
    const report = try check(arena, cfg, &plugins);
    try std.testing.expect(report.invalid);
    try std.testing.expectEqual(@as(usize, 3), report.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, report.diagnostics[0], "theme") != null);
    const relaxed = [_]plugin.Registry.Plugin{.{ .id = "lint" }};
    try std.testing.expect(!(try check(arena, cfg, &relaxed)).invalid);
}

test "config patches accept plugin entries and check declared schemas" {
    const io = std.testing.io;
    const config_edit = @import("config_edit.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try config_edit.pathFor(a, .user, base, base);
    const plugins = [_]plugin.Registry.Plugin{.{ .id = "lint", .config_schema = "{\"type\":\"object\",\"properties\":{\"level\":{\"type\":\"integer\"}}}" }};
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"plugin\":{\"lint\":{\"level\":\"high\"}}}", .{});
    try std.testing.expectError(error.InvalidPluginConfig, config_edit.patchFileFor(a, io, path, bad, &plugins));
    const good = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"plugin\":{\"lint\":{\"level\":2},\"other\":{\"any\":true}}}", .{});
    try config_edit.patchFileFor(a, io, path, good, &plugins);
    const other_top = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"theme\":\"dark\"}", .{});
    try std.testing.expectError(error.InvalidPatch, config_edit.patchFileFor(a, io, path, other_top, &plugins));
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const cfg = try config.load(a, io, &env, base, base);
    try std.testing.expectEqual(@as(i64, 2), cfg.pluginOptions("lint").?.object.get("level").?.integer);
    const shown = try config_edit.view(a, cfg);
    try std.testing.expect(shown.object.get("config").?.object.get("plugin").?.object.get("other") != null);
}
