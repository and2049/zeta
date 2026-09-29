//! The `register` message an extension sends first, checked and typed.
//! See docs/extensions.md for the shape.
const std = @import("std");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Hook = enum { session_start, prompt_submit, tool_pre, permission, tool_post, turn_stop };

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema text.
    parameters: []const u8,
    permission: plugin.tool.Permission = .{},
    side_effect: plugin.tool.SideEffect = .workspace,
    timeout_ms: ?u64 = null,
    sequential: bool = false,
    /// False: an abort waits for the call instead of cancelling it.
    cancellable: bool = true,
};

pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    argument_hint: ?[]const u8 = null,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    context: u64 = 0,
    output: u64 = 0,
    images: bool = false,
    /// The model takes a thinking level.
    reasoning: bool = false,
};

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    models: []const Model = &.{},
    env: []const []const u8 = &.{},
};

pub const Registration = struct {
    name: []const u8,
    description: []const u8 = "",
    tools: []const Tool = &.{},
    commands: []const Command = &.{},
    hooks: []const Hook = &.{},
    providers: []const Provider = &.{},
};

/// Everything returned lives in `arena`.
pub fn parse(arena: Allocator, text: []const u8) !Registration {
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return error.InvalidRegister;
    if (root != .object) return error.InvalidRegister;
    const o = root.object;
    var out: Registration = .{ .name = try str(o, "name") orelse return error.RegisterWithoutName };
    out.description = try str(o, "description") orelse "";
    var tools: std.ArrayList(Tool) = .empty;
    for (try list(o, "tools")) |item| try tools.append(arena, try tool(arena, item));
    out.tools = tools.items;
    var commands: std.ArrayList(Command) = .empty;
    for (try list(o, "commands")) |item| {
        if (item != .object) return error.InvalidCommand;
        try commands.append(arena, .{
            .name = try str(item.object, "name") orelse return error.InvalidCommand,
            .description = try str(item.object, "description") orelse "",
            .argument_hint = try str(item.object, "argumentHint"),
        });
    }
    out.commands = commands.items;
    var hooks: std.ArrayList(Hook) = .empty;
    for (try list(o, "hooks")) |item| {
        if (item != .string) return error.InvalidHook;
        try hooks.append(arena, std.meta.stringToEnum(Hook, item.string) orelse return error.UnknownHookPoint);
    }
    out.hooks = hooks.items;
    var providers: std.ArrayList(Provider) = .empty;
    for (try list(o, "providers")) |item| try providers.append(arena, try provider(arena, item));
    out.providers = providers.items;
    return out;
}

fn tool(arena: Allocator, v: Value) !Tool {
    if (v != .object) return error.InvalidTool;
    const o = v.object;
    var out: Tool = .{
        .name = try str(o, "name") orelse return error.InvalidTool,
        .description = try str(o, "description") orelse "",
        .parameters = try std.json.Stringify.valueAlloc(arena, o.get("parameters") orelse Value{ .object = .empty }, .{}),
    };
    if (o.get("sequential")) |b| out.sequential = switch (b) {
        .bool => |value| value,
        else => return error.InvalidTool,
    };
    if (o.get("cancellable")) |b| out.cancellable = switch (b) {
        .bool => |value| value,
        else => return error.InvalidTool,
    };
    if (try str(o, "sideEffect")) |effect| out.side_effect = std.meta.stringToEnum(plugin.tool.SideEffect, effect) orelse return error.InvalidTool;
    if (o.get("timeoutMs")) |t| out.timeout_ms = switch (t) {
        .integer => |i| if (i > 0) @intCast(i) else return error.InvalidTool,
        .null => null,
        else => return error.InvalidTool,
    };
    if (o.get("permission")) |p| {
        if (p != .object) return error.InvalidTool;
        out.permission = .{
            .action = try str(p.object, "action"),
            .target = if (try str(p.object, "target")) |t| std.meta.stringToEnum(plugin.tool.Target, t) orelse return error.InvalidTool else .none,
            .arg = try str(p.object, "arg") orelse "",
        };
    }
    return out;
}

fn provider(arena: Allocator, v: Value) !Provider {
    if (v != .object) return error.InvalidProvider;
    const o = v.object;
    const id = try str(o, "id") orelse return error.InvalidProvider;
    if (id.len == 0 or std.mem.eql(u8, id, "*") or std.mem.indexOfScalar(u8, id, '/') != null) return error.InvalidProvider;
    var models: std.ArrayList(Model) = .empty;
    for (try list(o, "models")) |item| {
        if (item != .object) return error.InvalidProvider;
        const m = item.object;
        const model_id = try str(m, "id") orelse return error.InvalidProvider;
        try models.append(arena, .{
            .id = model_id,
            .name = try str(m, "name") orelse model_id,
            .context = number(m.get("context")),
            .output = number(m.get("output")),
            .images = if (m.get("images")) |b| b == .bool and b.bool else false,
            .reasoning = if (m.get("reasoning")) |b| b == .bool and b.bool else false,
        });
    }
    var env: std.ArrayList([]const u8) = .empty;
    for (try list(o, "env")) |item| {
        if (item != .string) return error.InvalidProvider;
        try env.append(arena, item.string);
    }
    return .{ .id = id, .name = try str(o, "name") orelse id, .models = models.items, .env = env.items };
}

fn str(o: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    return switch (o.get(name) orelse return null) {
        .string => |s| s,
        .null => null,
        else => error.InvalidRegister,
    };
}

fn list(o: std.json.ObjectMap, name: []const u8) ![]const Value {
    return switch (o.get(name) orelse return &.{}) {
        .array => |a| a.items,
        .null => &.{},
        else => error.InvalidRegister,
    };
}

fn number(v: ?Value) u64 {
    return switch (v orelse return 0) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}

test "a full registration and the mistakes it rejects" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a,
        \\{"type":"register","name":"hello",
        \\ "tools":[{"name":"wc","description":"count","parameters":{"type":"object"},"permission":{"target":"path","arg":"file"},"sideEffect":"read","timeoutMs":500,"sequential":true,"cancellable":false}],
        \\ "commands":[{"name":"sum","argumentHint":"<path>"}],
        \\ "hooks":["tool_pre","turn_stop"],
        \\ "providers":[{"id":"echo","models":[{"id":"e1","context":100,"images":true}],"env":["ECHO_KEY"]}]}
    );
    try std.testing.expectEqualStrings("hello", r.name);
    try std.testing.expectEqual(plugin.tool.Target.path, r.tools[0].permission.target);
    try std.testing.expectEqual(plugin.tool.SideEffect.read, r.tools[0].side_effect);
    try std.testing.expectEqual(@as(?u64, 500), r.tools[0].timeout_ms);
    try std.testing.expect(!r.tools[0].cancellable);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", r.tools[0].parameters);
    try std.testing.expectEqualStrings("<path>", r.commands[0].argument_hint.?);
    try std.testing.expectEqual(Hook.turn_stop, r.hooks[1]);
    try std.testing.expectEqualStrings("echo", r.providers[0].name);
    try std.testing.expect(r.providers[0].models[0].images);
    try std.testing.expectError(error.RegisterWithoutName, parse(a, "{\"type\":\"register\"}"));
    try std.testing.expectError(error.UnknownHookPoint, parse(a, "{\"name\":\"x\",\"hooks\":[\"context_build\"]}"));
    try std.testing.expectError(error.InvalidProvider, parse(a, "{\"name\":\"x\",\"providers\":[{\"id\":\"*\"}]}"));
    try std.testing.expectError(error.InvalidTool, parse(a, "{\"name\":\"x\",\"tools\":[{\"name\":\"t\",\"sequential\":\"true\"}]}"));
    try std.testing.expectError(error.InvalidTool, parse(a, "{\"name\":\"x\",\"tools\":[{\"name\":\"t\",\"cancellable\":0}]}"));
}
