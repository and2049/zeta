//! A dispatch tool runs a deferred tool as if it had been called directly.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Bus = @import("bus.zig").Bus;
const tools_mod = @import("tools.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Call = proto.message.ToolCall;

fn echo(_: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    return .{ .text = try std.fmt.allocPrint(arena, "echo {s}", .{args.object.get("text").?.string}) };
}

fn unused(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    return error.NotCalled;
}

/// Records which tool the permission gate saw.
const Gate = struct {
    seen: [4][]const u8 = undefined,
    calls: [4][]const u8 = undefined,
    count: usize = 0,
    fn check(ctx: ?*anyopaque, _: Allocator, _: Io, _: []const u8, tool: plugin.tool.Tool, _: *std.json.Value, call: Call) anyerror!tools_mod.Verdict {
        const g: *Gate = @ptrCast(@alignCast(ctx.?));
        g.seen[g.count] = tool.name;
        g.calls[g.count] = call.name;
        g.count += 1;
        return .allow;
    }
};

test "a dispatch call runs the deferred tool through its own schema and permission" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const tools: []const plugin.tool.Tool = &.{
        .{ .name = "call", .description = "", .input_schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"arguments\":{\"type\":\"object\"}},\"required\":[\"name\"]}", .dispatch = true, .execute = unused },
        .{ .name = "hidden_echo", .description = "", .input_schema = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}", .deferred = true, .execute = echo },
        .{ .name = "visible", .description = "", .input_schema = "{}", .execute = echo },
    };
    const calls: []const Call = &.{
        .{ .id = "1", .name = "call", .arguments = "{\"name\":\"hidden_echo\",\"arguments\":{\"text\":\"hi\"}}" },
        .{ .id = "2", .name = "call", .arguments = "{\"name\":\"hidden_echo\",\"arguments\":{}}" },
        .{ .id = "3", .name = "call", .arguments = "{\"name\":\"visible\",\"arguments\":{\"text\":\"x\"}}" },
    };
    var gate: Gate = .{};
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const batch = try tools_mod.execute(arena.allocator(), a, io, &bus, "s", "/p", tools, calls, false, .{ .ctx = &gate, .check = Gate.check }, null, .{}, null);
    const out = batch.outcomes;
    try std.testing.expectEqualStrings("echo hi", out[0].text);
    try std.testing.expect(!out[0].is_error);
    try std.testing.expect(std.mem.startsWith(u8, out[1].text, "Invalid arguments for 'hidden_echo'"));
    // Only deferred tools are reached this way.
    try std.testing.expectEqualStrings("No tool 'visible' to call this way; search for one first.", out[2].text);
    try std.testing.expectEqual(@as(usize, 1), gate.count);
    try std.testing.expectEqualStrings("hidden_echo", gate.seen[0]);
    // Permission hooks match on the call's name: the target's.
    try std.testing.expectEqualStrings("hidden_echo", gate.calls[0]);
}

/// Records what hooks and tools saw, in order.
const Log = struct {
    var mutex: Io.Mutex = .init;
    var items: [16][]const u8 = undefined;
    var count: usize = 0;

    fn add(io: Io, what: []const u8) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        items[count] = what;
        count += 1;
    }

    fn index(what: []const u8) usize {
        for (items[0..count], 0..) |item, i| if (std.mem.eql(u8, item, what)) return i;
        return std.math.maxInt(usize);
    }

    fn pre(_: ?*anyopaque, _: Allocator, io: Io, _: plugin.hook.Scope, call: plugin.hook.Call) anyerror!plugin.hook.ToolPre {
        if (std.mem.eql(u8, call.name, "hidden_echo")) add(io, "pre hidden_echo");
        return .@"continue";
    }

    fn post(_: ?*anyopaque, _: Allocator, io: Io, _: plugin.hook.Scope, call: plugin.hook.Call, _: plugin.tool.Result) anyerror!plugin.hook.ToolPost {
        if (std.mem.eql(u8, call.name, "hidden_echo")) add(io, "post hidden_echo");
        return .@"continue";
    }

    fn slow(_: ?*anyopaque, _: Allocator, io: Io, _: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
        const name = args.object.get("text").?.string;
        add(io, if (std.mem.eql(u8, name, "a")) "start a" else if (std.mem.eql(u8, name, "b")) "start b" else "start seq");
        try io.sleep(.fromMilliseconds(20), .awake);
        add(io, if (std.mem.eql(u8, name, "a")) "end a" else if (std.mem.eql(u8, name, "b")) "end b" else "end seq");
        return .{ .text = "ok" };
    }
};

test "hooks see the deferred tool's name, and a sequential target is a barrier" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    Log.count = 0;
    const schema = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}";
    const tools: []const plugin.tool.Tool = &.{
        .{ .name = "call", .description = "", .input_schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"arguments\":{\"type\":\"object\"}},\"required\":[\"name\"]}", .dispatch = true, .execute = unused },
        .{ .name = "hidden_echo", .description = "", .input_schema = schema, .deferred = true, .execution_mode = .sequential, .execute = Log.slow },
        .{ .name = "parallel", .description = "", .input_schema = schema, .execute = Log.slow },
    };
    const calls: []const Call = &.{
        .{ .id = "1", .name = "parallel", .arguments = "{\"text\":\"a\"}" },
        .{ .id = "2", .name = "call", .arguments = "{\"name\":\"hidden_echo\",\"arguments\":{\"text\":\"seq\"}}" },
        .{ .id = "3", .name = "parallel", .arguments = "{\"text\":\"b\"}" },
    };
    const hooks: @import("hooks.zig").Hooks = .{ .list = &.{
        .{ .plugin = "t", .value = .{ .point = .{ .tool_pre = Log.pre } } },
        .{ .plugin = "t", .value = .{ .point = .{ .tool_post = Log.post } } },
    } };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const batch = try tools_mod.execute(arena.allocator(), a, io, &bus, "s", "/p", tools, calls, false, null, null, hooks, null);
    for (batch.outcomes) |o| try std.testing.expect(!o.is_error);
    try std.testing.expect(Log.index("pre hidden_echo") < Log.index("start seq"));
    try std.testing.expect(Log.index("end seq") < Log.index("post hidden_echo"));
    try std.testing.expect(Log.index("end a") < Log.index("start seq"));
    try std.testing.expect(Log.index("end seq") < Log.index("start b"));
}
