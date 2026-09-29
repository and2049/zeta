//! The live listing behind `/registry`, `/config` and the inspect tool. It is
//! built from the same view a run uses, so it shows what a run would see.
//! Everything returned lives in `arena`.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const config = @import("config.zig");
const config_edit = @import("config_edit.zig");
const plugin_config = @import("plugin_config.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Section = enum { summary, plugins, tools, hooks, providers, commands, config, diagnostics };

/// Everything `/registry` returns: tools, prompt sections, hooks, providers,
/// apis, plugins, commands and diagnostics, plus what the resource loaders
/// list (skills).
pub fn registry(rt: *Runtime, arena: Allocator, location: []const u8, cfg: config.Config) !Value {
    var result: Value = if (rt.resources) |loader| if (loader.inspect) |read| try read(loader.ctx, arena, rt.io, cfg, location) else .{ .object = .empty } else .{ .object = .empty };
    if (result != .object) return error.InvalidInspection;
    const run = try rt.runView(arena, location, cfg);
    const view = run.registry;
    var tools: std.ArrayList(Value) = .empty;
    for (run.tools, run.sources) |tool, source| try tools.append(arena, try asValue(arena, .{
        .name = tool.name,
        .plugin = source,
        .description = tool.description,
        .inputSchema = try std.json.parseFromSliceLeaky(Value, arena, tool.input_schema, .{}),
        .sideEffect = tool.side_effect,
        .permission = tool.permission,
        .executionMode = tool.execution_mode,
        .timeoutMs = tool.timeout_ms,
        .cancellable = tool.cancellable,
        .resultBudget = tool.result_budget,
    }));
    var sections: std.ArrayList([]const u8) = .empty;
    for (run.sections) |part| try sections.append(arena, part.name);
    var hooks: std.ArrayList(Value) = .empty;
    for (view.hooks) |h| try hooks.append(arena, try asValue(arena, .{ .plugin = h.plugin, .point = @tagName(h.value.point) }));
    var providers: std.ArrayList(Value) = .empty;
    for (view.providers) |p| try providers.append(arena, try asValue(arena, .{ .id = p.value.id, .name = p.value.name, .plugin = p.plugin }));
    var apis: std.ArrayList([]const u8) = .empty;
    for (view.apis) |api| try apis.append(arena, api.value.id);
    var plugins: std.ArrayList(Value) = .empty;
    for (view.plugins) |p| try plugins.append(arena, try asValue(arena, .{ .id = p.id, .layer = p.layer, .source = p.source }));

    try result.object.put(arena, "tools", .{ .array = tools.toManaged(arena) });
    try result.object.put(arena, "prompt_sections", try asValue(arena, sections.items));
    try result.object.put(arena, "hooks", .{ .array = hooks.toManaged(arena) });
    try result.object.put(arena, "providers", .{ .array = providers.toManaged(arena) });
    try result.object.put(arena, "apis", try asValue(arena, apis.items));
    try result.object.put(arena, "plugins", .{ .array = plugins.toManaged(arena) });
    const listing = try @import("commands.zig").list(rt, arena, location);
    var commands: std.ArrayList(Value) = .empty;
    for (listing.commands) |c| try commands.append(arena, try asValue(arena, .{ .name = c.name, .description = c.description, .argument_hint = c.argument_hint, .source = c.source, .path = c.path }));
    try result.object.put(arena, "commands", .{ .array = commands.toManaged(arena) });
    // Live state of plugins loaded from outside the binary (e.g. `mcp`).
    var statuses = try rt.registry.loaders.statuses(rt.io, arena, location);
    for (statuses.keys(), statuses.values()) |key, value| try result.object.put(arena, key, value);
    statuses.deinit(arena);
    const diagnostics = try std.mem.concat(arena, []const u8, &.{ run.diagnostics, listing.diagnostics });
    try result.object.put(arena, "diagnostics", try asValue(arena, diagnostics));
    return result;
}

/// The effective config with each value's source layer (secrets redacted)
/// and config diagnostics.
pub fn configView(rt: *Runtime, arena: Allocator, location: []const u8, cfg: config.Config) !Value {
    var result = try config_edit.view(arena, cfg);
    _ = try rt.registry.activate(arena, location);
    const view = try rt.registry.view(arena, location);
    const report = try plugin_config.check(arena, cfg, view.plugins);
    try result.object.put(arena, "diagnostics", try asValue(arena, report.diagnostics));
    return result;
}

/// One section of the listing. `summary` gives counts and the section names.
pub fn section(rt: *Runtime, arena: Allocator, location: []const u8, cfg: config.Config, which: Section) !Value {
    if (which == .config) return configView(rt, arena, location, cfg);
    const all = try registry(rt, arena, location, cfg);
    var result: std.json.ObjectMap = .empty;
    if (which == .summary) {
        try result.put(arena, "location", .{ .string = location });
        if (cfg.model) |model| try result.put(arena, "model", .{ .string = model });
        var counts: std.json.ObjectMap = .empty;
        var it = all.object.iterator();
        while (it.next()) |entry| if (entry.value_ptr.* == .array) {
            try counts.put(arena, entry.key_ptr.*, .{ .integer = @intCast(entry.value_ptr.array.items.len) });
        };
        try result.put(arena, "counts", .{ .object = counts });
        var names: std.ArrayList([]const u8) = .empty;
        for (std.enums.values(Section)[1..]) |s| try names.append(arena, @tagName(s));
        try result.put(arena, "sections", try asValue(arena, names.items));
        return .{ .object = result };
    }
    const keys: []const []const u8 = switch (which) {
        .summary, .config => unreachable,
        .plugins => &.{"plugins"},
        .tools => &.{ "tools", "prompt_sections" },
        .hooks => &.{"hooks"},
        .providers => &.{ "providers", "apis" },
        .commands => &.{"commands"},
        .diagnostics => &.{"diagnostics"},
    };
    for (keys) |key| if (all.object.get(key)) |value| try result.put(arena, key, value);
    // Resource-loader listings (e.g. skills) belong with the plugins.
    if (which == .plugins) {
        var it = all.object.iterator();
        while (it.next()) |entry| if (!known(entry.key_ptr.*)) try result.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .object = result };
}

fn known(key: []const u8) bool {
    for ([_][]const u8{ "tools", "prompt_sections", "hooks", "providers", "apis", "plugins", "commands", "diagnostics" }) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

pub fn asValue(arena: Allocator, value: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, try std.json.Stringify.valueAlloc(arena, value, .{}), .{});
}

test "sections select from the run's listing and the summary counts it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const plugin = @import("plugin");
    const Stub = struct {
        fn run(_: ?*anyopaque, _: Allocator, _: std.Io, _: []const u8, _: Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
            return .{ .text = "" };
        }
        fn listing(_: ?*anyopaque, arena: Allocator, _: std.Io, _: config.Config, _: []const u8) anyerror!Value {
            return asValue(arena, .{ .skills = &[_][]const u8{"demo"} });
        }
        fn prepare(_: ?*anyopaque, _: Allocator, _: std.Io, _: []const u8, _: config.Config, _: []const plugin.tool.Tool) anyerror!Runtime.Prepared {
            return .{};
        }
    };
    var reg: plugin.Registry = .init(a, io);
    defer reg.deinit();
    try reg.addTool(try reg.addPlugin(.{ .id = "echo" }), .{ .name = "echo", .description = "", .input_schema = "{}", .execute = Stub.run });
    try reg.addTool(try reg.addPlugin(.{ .id = "zeta_inspect" }), .{ .name = "zeta_inspect", .description = "", .input_schema = "{}", .execute = Stub.run });
    var bus: @import("bus.zig").Bus = .init(a, io);
    defer bus.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var rt = Runtime.init(a, io, &bus, &reg, &env, .{ .config_dir = dir, .sessions_dir = dir, .resources = .{ .prepare = Stub.prepare, .inspect = Stub.listing } });
    defer rt.deinit();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try section(&rt, arena, dir, .{}, .summary);
    const counts = summary.object.get("counts").?.object;
    try std.testing.expectEqual(@as(i64, 1), counts.get("tools").?.integer);
    try std.testing.expectEqual(@as(i64, 1), counts.get("skills").?.integer);
    const tools = try section(&rt, arena, dir, .{}, .tools);
    try std.testing.expectEqualStrings("echo", tools.object.get("tools").?.array.items[0].object.get("name").?.string);
    const enabled = try section(&rt, arena, dir, .{ .inspect_tool = true }, .tools);
    try std.testing.expectEqual(@as(usize, 2), enabled.object.get("tools").?.array.items.len);
    try std.testing.expectEqualStrings("zeta_inspect", enabled.object.get("tools").?.array.items[1].object.get("name").?.string);
    try std.testing.expect(tools.object.get("hooks") == null);
    const plugins = try section(&rt, arena, dir, .{}, .plugins);
    try std.testing.expect(plugins.object.get("skills") != null);
    const cfg = try section(&rt, arena, dir, .{}, .config);
    try std.testing.expect(cfg.object.get("config") != null and cfg.object.get("diagnostics") != null);
}
