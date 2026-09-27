//! Aborting a batch: a non-cancellable tool finishes and keeps its result.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Bus = @import("bus.zig").Bus;
const tools_mod = @import("tools.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Call = proto.message.ToolCall;

fn slow(_: ?*anyopaque, arena: Allocator, io: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    try Io.sleep(io, .fromMilliseconds(100), .awake);
    return .{ .text = try arena.dupe(u8, "finished") };
}

const Run = struct {
    batch: tools_mod.Batch = undefined,
    fn go(r: *Run, arena: Allocator, io: Io, bus: *Bus, tools: []const plugin.tool.Tool, calls: []const Call) Io.Cancelable!void {
        r.batch = tools_mod.execute(arena, std.testing.allocator, io, bus, "s", "/p", tools, calls, false, null, null, .{}, null) catch |err| .{ .outcomes = &.{}, .failure = err };
    }
};

test "an abort waits for a tool that must not be interrupted, and keeps its result" {
    const io = std.testing.io;
    var bus: Bus = .init(std.testing.allocator, io);
    defer bus.deinit();
    const tools: []const plugin.tool.Tool = &.{
        .{ .name = "careful", .description = "", .input_schema = "{}", .cancellable = false, .execute = slow },
        .{ .name = "quick", .description = "", .input_schema = "{}", .execute = slow },
    };
    const calls: []const Call = &.{ .{ .id = "1", .name = "careful", .arguments = "{}" }, .{ .id = "2", .name = "quick", .arguments = "{}" } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var run: Run = .{};
    var future = try io.concurrent(Run.go, .{ &run, arena.allocator(), io, &bus, tools, calls });
    try Io.sleep(io, .fromMilliseconds(20), .awake);
    future.cancel(io) catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), run.batch.failure);
    try std.testing.expectEqualStrings("finished", run.batch.outcomes[0].text);
    try std.testing.expect(!run.batch.outcomes[0].is_error);
    try std.testing.expect(run.batch.outcomes[1].is_error);
}

test "an abort during a sequential tool that must not be interrupted keeps its result and ends the batch" {
    const io = std.testing.io;
    var bus: Bus = .init(std.testing.allocator, io);
    defer bus.deinit();
    const tools: []const plugin.tool.Tool = &.{
        .{ .name = "careful", .description = "", .input_schema = "{}", .cancellable = false, .execution_mode = .sequential, .execute = slow },
        .{ .name = "after", .description = "", .input_schema = "{}", .execution_mode = .sequential, .execute = slow },
    };
    const calls: []const Call = &.{ .{ .id = "1", .name = "careful", .arguments = "{}" }, .{ .id = "2", .name = "after", .arguments = "{}" } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var run: Run = .{};
    var future = try io.concurrent(Run.go, .{ &run, arena.allocator(), io, &bus, tools, calls });
    try Io.sleep(io, .fromMilliseconds(20), .awake);
    future.cancel(io) catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), run.batch.failure);
    try std.testing.expectEqualStrings("finished", run.batch.outcomes[0].text);
    // The next tool never started.
    try std.testing.expect(run.batch.outcomes[1].is_error);
}

fn slowBig(_: ?*anyopaque, arena: Allocator, io: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    try Io.sleep(io, .fromMilliseconds(100), .awake);
    const text = try arena.alloc(u8, 200 * 1024);
    @memset(text, 'x');
    return .{ .text = text };
}

test "an abort is not lost while a waited-for tool's large result is saved" {
    const io = std.testing.io;
    var bus: Bus = .init(std.testing.allocator, io);
    defer bus.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const tools: []const plugin.tool.Tool = &.{
        .{ .name = "careful", .description = "", .input_schema = "{}", .cancellable = false, .execution_mode = .sequential, .execute = slowBig },
        .{ .name = "after", .description = "", .input_schema = "{}", .execution_mode = .sequential, .execute = slow },
    };
    const calls: []const Call = &.{ .{ .id = "1", .name = "careful", .arguments = "{}" }, .{ .id = "2", .name = "after", .arguments = "{}" } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Big = struct {
        batch: tools_mod.Batch = undefined,
        fn go(r: *@This(), a: Allocator, t_io: Io, b: *Bus, ts: []const plugin.tool.Tool, cs: []const Call, artifacts: []const u8) Io.Cancelable!void {
            r.batch = tools_mod.execute(a, std.testing.allocator, t_io, b, "s", "/p", ts, cs, false, null, null, .{}, artifacts) catch |err| .{ .outcomes = &.{}, .failure = err };
        }
    };
    var run: Big = .{};
    var future = try io.concurrent(Big.go, .{ &run, arena.allocator(), io, &bus, tools, calls, dir });
    try Io.sleep(io, .fromMilliseconds(20), .awake);
    future.cancel(io) catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), run.batch.failure);
    try std.testing.expect(!run.batch.outcomes[0].is_error);
    try std.testing.expect(run.batch.outcomes[1].is_error);
}

test "an abort that waits for a tool also waits for its result hooks" {
    const io = std.testing.io;
    var bus: Bus = .init(std.testing.allocator, io);
    defer bus.deinit();
    const Redact = struct {
        fn post(_: ?*anyopaque, arena: Allocator, _: Io, _: plugin.hook.Scope, _: plugin.hook.Call, result: plugin.tool.Result) anyerror!plugin.hook.ToolPost {
            return .{ .replace = .{ .text = try std.fmt.allocPrint(arena, "{s} (redacted)", .{result.text}) } };
        }
        batch: tools_mod.Batch = undefined,
        fn go(r: *@This(), arena: Allocator, t_io: Io, b: *Bus, ts: []const plugin.tool.Tool, cs: []const Call) Io.Cancelable!void {
            const hooks: @import("hooks.zig").Hooks = .{ .list = &.{.{ .plugin = "t", .value = .{ .point = .{ .tool_post = post } } }} };
            r.batch = tools_mod.execute(arena, std.testing.allocator, t_io, b, "s", "/p", ts, cs, false, null, null, hooks, null) catch |err| .{ .outcomes = &.{}, .failure = err };
        }
    };
    const tools: []const plugin.tool.Tool = &.{.{ .name = "careful", .description = "", .input_schema = "{}", .cancellable = false, .execute = slow }};
    const calls: []const Call = &.{.{ .id = "1", .name = "careful", .arguments = "{}" }};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var run: Redact = .{};
    var future = try io.concurrent(Redact.go, .{ &run, arena.allocator(), io, &bus, tools, calls });
    try Io.sleep(io, .fromMilliseconds(20), .awake);
    future.cancel(io) catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), run.batch.failure);
    try std.testing.expectEqualStrings("finished (redacted)", run.batch.outcomes[0].text);
}
