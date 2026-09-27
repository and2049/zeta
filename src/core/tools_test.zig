const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Bus = @import("bus.zig").Bus;
const budget = @import("budget.zig");
const tools_mod = @import("tools.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Call = proto.message.ToolCall;

/// Runs a batch that is expected to complete.
pub fn execute(arena: Allocator, gpa: Allocator, io: Io, bus: *Bus, session: []const u8, location: []const u8, tools: []const plugin.tool.Tool, calls: []const Call, truncated: bool, approval: ?tools_mod.Approval, timeout_ms: ?u64) ![]tools_mod.Outcome {
    const batch = try tools_mod.execute(arena, gpa, io, bus, session, location, tools, calls, truncated, approval, timeout_ms, .{}, null);
    if (batch.failure) |err| return err;
    return batch.outcomes;
}

const TestTool = struct {
    active: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    barrier_clean: std.atomic.Value(bool) = .init(false),
    canceled: std.atomic.Value(bool) = .init(false),

    fn run(ctx: ?*anyopaque, arena: Allocator, io: Io, _: []const u8, args: std.json.Value, progress_sink: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
        const t: *TestTool = @ptrCast(@alignCast(ctx.?));
        const n = t.active.fetchAdd(1, .seq_cst) + 1;
        defer _ = t.active.fetchSub(1, .seq_cst);
        _ = t.peak.fetchMax(n, .seq_cst);
        if (args.object.get("barrier") != null) t.barrier_clean.store(n == 1, .seq_cst);
        if (args.object.get("slow") != null) {
            Io.sleep(io, .fromMilliseconds(30), .awake) catch |err| {
                if (err == error.Canceled) t.canceled.store(true, .seq_cst);
                return err;
            };
        } else {
            try Io.sleep(io, .fromMilliseconds(3), .awake);
        }
        try progress_sink.emit("working");
        return .{ .text = try arena.dupe(u8, "éééééééééééééééé") };
    }
};

test "parallel batch, sequential barrier, source ordering, validation and event progress" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var stub: TestTool = .{};
    const tools: []const plugin.tool.Tool = &.{
        .{ .name = "parallel", .description = "", .input_schema = "{\"type\":\"object\",\"required\":[\"ok\"]}", .ctx = &stub, .execute = TestTool.run, .result_budget = .{ .max_bytes = budget.notice.len + 3 } },
        .{ .name = "barrier", .description = "", .input_schema = "{}", .execution_mode = .sequential, .ctx = &stub, .execute = TestTool.run },
    };
    const calls: []const Call = &.{
        .{ .id = "1", .name = "parallel", .arguments = "{\"ok\":true}" },
        .{ .id = "2", .name = "parallel", .arguments = "{\"ok\":true}" },
        .{ .id = "3", .name = "barrier", .arguments = "{\"barrier\":true}" },
        .{ .id = "4", .name = "missing", .arguments = "{}" },
        .{ .id = "5", .name = "parallel", .arguments = "{" },
        .{ .id = "6", .name = "parallel", .arguments = "{}" },
    };
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const results = try execute(arena_state.allocator(), a, io, &bus, "session", "/project", tools, calls, false, null, null);
    try std.testing.expectEqual(@as(usize, 6), results.len);
    try std.testing.expect(stub.peak.load(.seq_cst) >= 2);
    try std.testing.expect(stub.barrier_clean.load(.seq_cst));
    for (results, calls) |result, call| try std.testing.expectEqualStrings(call.id, result.call.id);
    try std.testing.expectEqualStrings("é\n[Tool output truncated]", results[0].text);
    try std.testing.expect(!results[0].is_error);
    try std.testing.expect(!results[2].is_error);
    for (results[3..]) |result| try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, results[3].text, "not available") != null);
    try std.testing.expectEqualStrings("Inv\n[Tool output truncated]", results[4].text);
    try std.testing.expectEqualStrings("Inv\n[Tool output truncated]", results[5].text);

    var saw_update = false;
    for (0..15) |_| { // Six start/end pairs, three successful updates.
        const frame = (try sub.next(io)).?;
        defer frame.release(a);
        var event_arena: std.heap.ArenaAllocator = .init(a);
        defer event_arena.deinit();
        const ev = try proto.event.Decoded.parse(event_arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, ev.type, proto.event.types.tool_execution_update)) {
            saw_update = true;
            try std.testing.expectEqualStrings("working", ev.data.object.get("partialResult").?.string);
        }
    }
    try std.testing.expect(saw_update);
}

test "deadline cancels execution and truncated calls never execute" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    var stub: TestTool = .{};
    const t: plugin.tool.Tool = .{ .name = "slow", .description = "", .input_schema = "{}", .timeout_ms = 1, .ctx = &stub, .execute = TestTool.run };
    const calls: []const Call = &.{.{ .id = "1", .name = "slow", .arguments = "{\"slow\":true}" }};
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const timed = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{t}, calls, false, null, null);
    try std.testing.expect(timed[0].is_error);
    try std.testing.expect(std.mem.indexOf(u8, timed[0].text, "Timeout") != null);
    try std.testing.expect(stub.canceled.load(.seq_cst));
    stub.canceled.store(false, .seq_cst);
    const truncated = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{t}, calls, true, null, null);
    try std.testing.expect(truncated[0].is_error);
    try std.testing.expect(std.mem.indexOf(u8, truncated[0].text, "truncated") != null);
    try std.testing.expect(!stub.canceled.load(.seq_cst));
}

test "approval receives validated arguments and denied tools do not run" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    var stub: TestTool = .{};
    const Gate = struct {
        fn check(_: ?*anyopaque, _: Allocator, _: Io, location: []const u8, tool: plugin.tool.Tool, args: *std.json.Value, call: Call) anyerror!tools_mod.Verdict {
            try std.testing.expectEqualStrings("/root", location);
            try std.testing.expectEqualStrings("blocked", tool.name);
            try std.testing.expectEqualStrings("id", call.id);
            try std.testing.expect(args.object.get("ok").?.bool);
            return .deny;
        }
    };
    const tool: plugin.tool.Tool = .{ .name = "blocked", .description = "", .input_schema = "{\"type\":\"object\",\"required\":[\"ok\"]}", .ctx = &stub, .execute = TestTool.run };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const outcomes = try execute(state.allocator(), a, io, &bus, "s", "/root", &.{tool}, &.{.{ .id = "id", .name = "blocked", .arguments = "{\"ok\":true}" }}, false, .{ .ctx = null, .check = Gate.check }, null);
    try std.testing.expect(outcomes[0].denied and outcomes[0].is_error);
    try std.testing.expectEqual(@as(usize, 0), stub.peak.load(.seq_cst));
}

test "unanswered approval uses the tool deadline and cancels cleanly" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    var canceled = std.atomic.Value(bool).init(false);
    const Gate = struct {
        fn check(ctx: ?*anyopaque, _: Allocator, task_io: Io, _: []const u8, _: plugin.tool.Tool, _: *std.json.Value, _: Call) anyerror!tools_mod.Verdict {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            Io.sleep(task_io, .fromMilliseconds(30), .awake) catch |err| {
                if (err == error.Canceled) flag.store(true, .seq_cst);
                return err;
            };
            return .allow;
        }
    };
    var stub: TestTool = .{};
    const tool: plugin.tool.Tool = .{ .name = "ask", .description = "", .input_schema = "{}", .timeout_ms = 1, .ctx = &stub, .execute = TestTool.run };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const outcomes = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{tool}, &.{.{ .id = "id", .name = "ask", .arguments = "{}" }}, false, .{ .ctx = &canceled, .check = Gate.check }, null);
    try std.testing.expect(outcomes[0].denied);
    try std.testing.expect(std.mem.indexOf(u8, outcomes[0].text, "Timeout") != null);
    try std.testing.expect(canceled.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), stub.peak.load(.seq_cst));
}

test "configured short deadline applies to inherited tool, explicit 120s wins" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    var stub: TestTool = .{};
    const base: plugin.tool.Tool = .{ .name = "wait", .description = "", .input_schema = "{}", .ctx = &stub, .execute = TestTool.run };
    const calls: []const Call = &.{.{ .id = "1", .name = "wait", .arguments = "{\"slow\":true}" }};
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const timed = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{base}, calls, false, null, 1);
    try std.testing.expect(timed[0].is_error);
    const overridden = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{blk: {
        var own = base;
        own.timeout_ms = 120_000;
        break :blk own;
    }}, calls, false, null, 1);
    try std.testing.expect(!overridden[0].is_error);
}

test "approval and execution share one tool deadline" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const Parts = struct {
        fn approve(_: ?*anyopaque, _: Allocator, task_io: Io, _: []const u8, _: plugin.tool.Tool, _: *std.json.Value, _: Call) !tools_mod.Verdict {
            try Io.sleep(task_io, .fromMilliseconds(25), .awake);
            return .allow;
        }
        fn run(_: ?*anyopaque, _: Allocator, task_io: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            try Io.sleep(task_io, .fromMilliseconds(25), .awake);
            return .{ .text = "would succeed with two separate 35ms deadlines" };
        }
    };
    const tool: plugin.tool.Tool = .{ .name = "combined", .description = "", .input_schema = "{}", .execute = Parts.run };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const outcomes = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{tool}, &.{.{ .id = "id", .name = "combined", .arguments = "{}" }}, false, .{ .ctx = null, .check = Parts.approve }, 35);
    try std.testing.expect(outcomes[0].is_error);
    try std.testing.expect(std.mem.indexOf(u8, outcomes[0].text, "Timeout") != null);
}

test "parallel denial skips following sequential barrier and still pairs every call" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const Gate = struct {
        fn check(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: plugin.tool.Tool, _: *std.json.Value, call: Call) !tools_mod.Verdict {
            return if (std.mem.eql(u8, call.id, "deny")) .deny else .allow;
        }
        fn fail(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.UnexpectedExecution;
        }
    };
    var called = std.atomic.Value(usize).init(0);
    const Allowed = struct {
        fn run(ctx: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            const count: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx.?));
            _ = count.fetchAdd(1, .seq_cst);
            return .{ .text = "done" };
        }
    };
    const defs: []const plugin.tool.Tool = &.{
        .{ .name = "parallel", .description = "", .input_schema = "{}", .ctx = &called, .execute = Allowed.run },
        .{ .name = "barrier", .description = "", .input_schema = "{}", .execution_mode = .sequential, .result_budget = .{ .max_bytes = 32 }, .execute = Gate.fail },
    };
    const calls: []const Call = &.{
        .{ .id = "allow", .name = "parallel", .arguments = "{}" },
        .{ .id = "deny", .name = "parallel", .arguments = "{}" },
        .{ .id = "later", .name = "barrier", .arguments = "{}" },
    };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const results = try execute(state.allocator(), a, io, &bus, "s", "/p", defs, calls, false, .{ .ctx = null, .check = Gate.check }, null);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqual(@as(usize, 1), called.load(.seq_cst));
    try std.testing.expect(results[1].denied and results[2].denied);
    try std.testing.expect(results[2].text.len <= 32);
    try std.testing.expect(std.mem.endsWith(u8, results[2].text, budget.notice));
}
