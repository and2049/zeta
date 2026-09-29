//! Tool pipeline tests for budgets, cancellation and mid-call permission checks.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Bus = @import("bus.zig").Bus;
const budget = @import("budget.zig");
const tools_mod = @import("tools.zig");
const execute = @import("tools_test.zig").execute;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Call = proto.message.ToolCall;

test "progress event is budgeted before entering the event bus" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    const Large = struct {
        fn run(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, sink: plugin.tool.ProgressSink) !plugin.tool.Result {
            var text: [10000]u8 = @splat('x');
            try sink.emit(&text);
            return .{ .text = "done" };
        }
    };
    const def: plugin.tool.Tool = .{ .name = "progress", .description = "", .input_schema = "{}", .result_budget = .{ .max_bytes = 128 }, .execute = Large.run };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    _ = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{def}, &.{.{ .id = "1", .name = "progress", .arguments = "{}" }}, false, null, null);
    for (0..3) |_| {
        const frame = (try sub.next(io)).?;
        defer frame.release(a);
        var decoded_state: std.heap.ArenaAllocator = .init(a);
        defer decoded_state.deinit();
        const event = try proto.event.Decoded.parse(decoded_state.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, proto.event.types.tool_execution_update)) {
            const partial = event.data.object.get("partialResult").?.string;
            try std.testing.expect(partial.len <= 128);
            try std.testing.expect(std.mem.endsWith(u8, partial, budget.notice));
        }
    }
}

test "oversized validation path is bounded in model outcome and end event" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    const Guard = struct {
        fn run(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.UnexpectedToolInvocation;
        }
    };
    const def: plugin.tool.Tool = .{
        .name = "strict",
        .description = "",
        .input_schema = "{\"type\":\"object\",\"additionalProperties\":false}",
        .result_budget = .{ .max_bytes = 96, .max_lines = 2 },
        .execute = Guard.run,
    };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const arena = state.allocator();
    const property = try arena.alloc(u8, 100_000);
    @memset(property, 'x');
    const args = try std.fmt.allocPrint(arena, "{{\"{s}\":1}}", .{property});
    const outcomes = try execute(arena, a, io, &bus, "s", "/p", &.{def}, &.{.{ .id = "large", .name = "strict", .arguments = args }}, false, null, null);
    const text = outcomes[0].text;
    try std.testing.expect(outcomes[0].is_error);
    try std.testing.expect(text.len <= def.result_budget.max_bytes);
    try std.testing.expect(std.mem.endsWith(u8, text, budget.notice));
    try std.testing.expect(std.mem.count(u8, text, "\n") < def.result_budget.max_lines);

    const start = (try sub.next(io)).?;
    defer start.release(a);
    const end = (try sub.next(io)).?;
    defer end.release(a);
    const event = try proto.event.Decoded.parse(arena, end.bytes);
    try std.testing.expectEqualStrings(proto.event.types.tool_execution_end, event.type);
    const result = event.data.object.get("result").?.object;
    const event_text = result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings(text, event_text);
}

test "canceled batch keeps finished outcomes and closes the interrupted call" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    const Parts = struct {
        fn ok(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return .{ .text = "written", .changes = &.{.{ .path = "a.txt", .before = "", .after = "x" }} };
        }
        fn cancel(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.Canceled;
        }
        fn never(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.UnexpectedExecution;
        }
    };
    const defs: []const plugin.tool.Tool = &.{
        .{ .name = "write", .description = "", .input_schema = "{}", .execute = Parts.ok },
        .{ .name = "stop", .description = "", .input_schema = "{}", .execution_mode = .sequential, .execute = Parts.cancel },
        .{ .name = "later", .description = "", .input_schema = "{}", .execute = Parts.never },
    };
    const calls: []const Call = &.{
        .{ .id = "done", .name = "write", .arguments = "{}" },
        .{ .id = "stopped", .name = "stop", .arguments = "{}" },
        .{ .id = "unstarted", .name = "later", .arguments = "{}" },
    };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const batch = try tools_mod.execute(state.allocator(), a, io, &bus, "s", "/p", defs, calls, false, null, null, .{}, null);
    try std.testing.expectEqual(error.Canceled, batch.failure.?);
    try std.testing.expectEqual(@as(usize, 3), batch.outcomes.len);
    try std.testing.expectEqualStrings("written", batch.outcomes[0].text);
    try std.testing.expect(!batch.outcomes[0].is_error);
    try std.testing.expectEqualStrings("a.txt", batch.outcomes[0].changes[0].path);
    for (batch.outcomes[1..]) |outcome| {
        try std.testing.expectEqualStrings(tools_mod.interrupted, outcome.text);
        try std.testing.expect(outcome.is_error and !outcome.denied);
    }

    // Every started call gets an end; the unstarted one gets neither.
    const want = [_]struct { []const u8, []const u8 }{
        .{ proto.event.types.tool_execution_start, "done" },
        .{ proto.event.types.tool_execution_end, "done" },
        .{ proto.event.types.tool_execution_start, "stopped" },
        .{ proto.event.types.tool_execution_end, "stopped" },
    };
    for (want) |expected| {
        const frame = (try sub.next(io)).?;
        defer frame.release(a);
        var decoded_state: std.heap.ArenaAllocator = .init(a);
        defer decoded_state.deinit();
        const event = try proto.event.Decoded.parse(decoded_state.allocator(), frame.bytes);
        try std.testing.expectEqualStrings(expected[0], event.type);
        try std.testing.expectEqualStrings(expected[1], event.data.object.get("toolCallId").?.string);
    }
}

test "a tool re-checks permission mid-call and a refusal denies the call" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const Parts = struct {
        fn check(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: plugin.tool.Tool, args: *std.json.Value, _: Call) !tools_mod.Verdict {
            return if (std.mem.startsWith(u8, args.object.get("url").?.string, "http://denied")) .deny else .allow;
        }
        fn fetch(_: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, _: std.json.Value, host: plugin.tool.ProgressSink) !plugin.tool.Result {
            var hop: std.json.ObjectMap = .empty;
            try hop.put(arena, "url", .{ .string = "http://allowed.test/next" });
            if (!try host.permit(.{ .object = hop })) return error.UnexpectedDenial;
            try hop.put(arena, "url", .{ .string = "http://denied.test/secret" });
            if (!try host.permit(.{ .object = hop })) return error.PermissionDenied;
            return .{ .text = "fetched the denied host" };
        }
    };
    const tool: plugin.tool.Tool = .{ .name = "fetch", .description = "", .input_schema = "{}", .execute = Parts.fetch };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const outcomes = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{tool}, &.{.{ .id = "id", .name = "fetch", .arguments = "{\"url\":\"http://allowed.test\"}" }}, false, .{ .ctx = null, .check = Parts.check }, null);
    try std.testing.expect(outcomes[0].denied and outcomes[0].is_error);
    try std.testing.expectEqualStrings("Tool execution denied by permission policy.", outcomes[0].text);
}

test "a mid-call approval that rewrites the arguments is a refusal" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const Parts = struct {
        var calls: usize = 0;
        fn check(_: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, _: plugin.tool.Tool, args: *std.json.Value, _: Call) !tools_mod.Verdict {
            calls += 1;
            // The upfront check passes as is; the mid-call one is rewritten.
            if (calls == 1) return .allow;
            var safe: std.json.ObjectMap = .empty;
            try safe.put(arena, "url", .{ .string = "http://safe.test" });
            args.* = .{ .object = safe };
            return .allow;
        }
        fn fetch(_: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, _: std.json.Value, host: plugin.tool.ProgressSink) !plugin.tool.Result {
            var hop: std.json.ObjectMap = .empty;
            try hop.put(arena, "url", .{ .string = "http://elsewhere.test" });
            if (!try host.permit(.{ .object = hop })) return error.PermissionDenied;
            return .{ .text = "followed the original redirect" };
        }
    };
    const tool: plugin.tool.Tool = .{ .name = "fetch", .description = "", .input_schema = "{}", .execute = Parts.fetch };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const outcomes = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{tool}, &.{.{ .id = "id", .name = "fetch", .arguments = "{\"url\":\"http://start.test\"}" }}, false, .{ .ctx = null, .check = Parts.check }, null);
    try std.testing.expect(outcomes[0].denied);
}

test "a failing tool's error result goes through tool_post" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const Parts = struct {
        fn fail(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.FileNotFound;
        }
        fn post(_: ?*anyopaque, arena: Allocator, _: Io, _: plugin.hook.Scope, _: plugin.hook.Call, result: plugin.tool.Result) anyerror!plugin.hook.ToolPost {
            if (!result.isError) return .@"continue";
            return .{ .replace = .{ .text = try std.fmt.allocPrint(arena, "{s} (seen by hook)", .{result.text}), .isError = true } };
        }
    };
    const tool: plugin.tool.Tool = .{ .name = "broken", .description = "", .input_schema = "{}", .execute = Parts.fail };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const hooks: @import("hooks.zig").Hooks = .{ .list = &.{.{ .plugin = "t", .value = .{ .point = .{ .tool_post = Parts.post } } }} };
    const batch = try tools_mod.execute(state.allocator(), a, io, &bus, "s", "/p", &.{tool}, &.{.{ .id = "id", .name = "broken", .arguments = "{}" }}, false, null, null, hooks, null);
    try std.testing.expect(batch.outcomes[0].is_error);
    try std.testing.expectEqualStrings("Tool 'broken' failed: FileNotFound (seen by hook)", batch.outcomes[0].text);
}

test "unknown tool error uses the default budget" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const name = try state.allocator().alloc(u8, 60 * 1024);
    @memset(name, 'q');
    const results = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{}, &.{.{ .id = "missing", .name = name, .arguments = "{}" }}, false, null, null);
    try std.testing.expect(results[0].is_error);
    try std.testing.expectEqual(@as(usize, 50 * 1024), results[0].text.len);
    try std.testing.expect(std.mem.endsWith(u8, results[0].text, budget.notice));
}

test "a tool that checks its own arguments gets any object, whatever its schema says" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(a, io);
    defer bus.deinit();
    const Parts = struct {
        fn run(_: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return .{ .text = try std.fmt.allocPrint(arena, "kind={s}", .{args.object.get("kind").?.string}) };
        }
    };
    // Both branches ignore `$ref` locally, so a strict check would reject
    // every value as matching both.
    const schema =
        \\{"type":"object","properties":{"kind":{"oneOf":[{"$ref":"#/$defs/a"},{"$ref":"#/$defs/b"}]}},"$defs":{"a":{"const":"a"},"b":{"const":"b"}}}
    ;
    const tool: plugin.tool.Tool = .{ .name = "remote", .description = "", .input_schema = schema, .schema_check = .partial, .execute = Parts.run };
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const outcomes = try execute(state.allocator(), a, io, &bus, "s", "/p", &.{tool}, &.{
        .{ .id = "ok", .name = "remote", .arguments = "{\"kind\":\"a\"}" },
        .{ .id = "bad", .name = "remote", .arguments = "[1]" },
    }, false, null, null);
    try std.testing.expectEqualStrings("kind=a", outcomes[0].text);
    try std.testing.expectEqualStrings("Invalid tool arguments: expected an object", outcomes[1].text);
}
