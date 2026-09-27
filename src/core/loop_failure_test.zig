const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bus = @import("bus.zig").Bus;
const Session = @import("session.zig").Session;
const Inbox = @import("inbox.zig").Inbox;
const Loop = @import("loop.zig").Loop;
const types = proto.event.types;

test "provider failure after partial tool arguments logs a parseable paired error result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_partial", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("initial", "run", .queue);
    const Partial = struct {
        fn stream(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) !void {
            try sink.emit(.{ .tool_call_start = .{ .index = 0, .id = "call_partial", .name = "dangerous" } });
            try sink.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"command\":" } });
            return error.StreamFailed;
        }
        fn execute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.ToolMustNotRun;
        }
    };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "partial", .stream = Partial.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "", .executable_tools = &.{.{ .name = "dangerous", .description = "", .input_schema = "{}", .execute = Partial.execute }} },
    };
    try loop.run();
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
    const assistant = session.messages.items[1];
    try std.testing.expectEqual(proto.message.StopReason.@"error", assistant.stopReason.?);
    try std.testing.expectEqualStrings("call_partial", assistant.content[0].tool_call.id);
    try std.testing.expectEqualStrings("{\"command\":", assistant.content[0].tool_call.arguments);
    const result = session.messages.items[2];
    try std.testing.expect(result.isError);
    try std.testing.expectEqualStrings("call_partial", result.toolCallId.?);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "not executed") != null);
}

test "stream cancellation after a tool call records an aborted assistant and result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_cancel", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("initial", "run", .queue);
    const Cancel = struct {
        fn stream(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) !void {
            try sink.emit(.{ .tool_call_start = .{ .index = 0, .id = "canceled_call", .name = "dangerous" } });
            return error.Canceled;
        }
    };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "cancel", .stream = Cancel.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "" },
    };
    try loop.run();
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
    try std.testing.expectEqual(proto.message.StopReason.aborted, session.messages.items[1].stopReason.?);
    try std.testing.expect(session.messages.items[2].isError);
    try std.testing.expectEqualStrings("canceled_call", session.messages.items[2].toolCallId.?);
}

test "worker cancel mid-stream pairs the orphan call and ends the turn before reporting" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_worker_cancel", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("initial", "run", .queue);
    try inbox.push("later", "must wait", .queue);
    const Cancel = struct {
        fn stream(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) !void {
            try sink.emit(.{ .tool_call_start = .{ .index = 0, .id = "orphan", .name = "dangerous" } });
            return error.Canceled;
        }
    };
    var state_mutex: Io.Mutex = .init;
    var inflight: ?proto.Message = null;
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .state_mutex = &state_mutex,
        .inflight = &inflight,
        .config = .{ .api = .{ .id = "cancel", .stream = Cancel.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "" },
    };
    try std.testing.expectError(error.Canceled, loop.run());
    const msgs = session.messages.items;
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqual(proto.message.StopReason.aborted, msgs[1].stopReason.?);
    try std.testing.expectEqualStrings("orphan", msgs[2].toolCallId.?);
    try std.testing.expect(msgs[2].isError);
    try std.testing.expect(!inbox.isEmpty()); // The canceled worker took nothing else.

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var saw_turn_end = false;
    while (true) {
        const frame = (try sub.next(io)).?;
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, types.turn_end)) saw_turn_end = true;
        if (std.mem.eql(u8, event.type, types.agent_end)) break;
    }
    try std.testing.expect(saw_turn_end);
}

test "canceled batch logs finished results, not interruptions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_partial_batch", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("initial", "run", .queue);
    const Batch = struct {
        fn stream(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) !void {
            try sink.emit(.{ .tool_call_start = .{ .index = 0, .id = "written", .name = "write" } });
            try sink.emit(.{ .tool_call_start = .{ .index = 1, .id = "stopped", .name = "stop" } });
            try sink.emit(.{ .done = .tool_use });
        }
        fn write(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return .{ .text = "Wrote a.txt" };
        }
        fn stop(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.Canceled;
        }
    };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "batch", .stream = Batch.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "", .executable_tools = &.{
            .{ .name = "write", .description = "", .input_schema = "{}", .execute = Batch.write },
            .{ .name = "stop", .description = "", .input_schema = "{}", .execution_mode = .sequential, .execute = Batch.stop },
        } },
    };
    try std.testing.expectError(error.Canceled, loop.run());
    const msgs = session.messages.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqualStrings("written", msgs[2].toolCallId.?);
    try std.testing.expectEqualStrings("Wrote a.txt", msgs[2].content[0].text);
    try std.testing.expect(!msgs[2].isError);
    try std.testing.expectEqualStrings("stopped", msgs[3].toolCallId.?);
    try std.testing.expect(msgs[3].isError);
}

const Flaky = struct {
    calls: usize = 0,
    /// Failures before success; each streams `partial` first when set.
    failures: usize,
    partial: bool = false,
    /// Largest history any request carried.
    most_messages: usize = 0,

    fn stream(ctx: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, request: plugin.provider.Request, sink: plugin.provider.Sink) !void {
        const f: *Flaky = @ptrCast(@alignCast(ctx.?));
        defer f.calls += 1;
        f.most_messages = @max(f.most_messages, request.messages.len);
        if (f.calls < f.failures) {
            if (f.partial) try sink.emit(.{ .text_delta = "partial" });
            try sink.emit(.{ .failure = .{ .message = "HTTP 503: overloaded", .retryable = true, .status = 503 } });
            return error.ProviderHttpError;
        }
        try sink.emit(.{ .text_delta = "recovered" });
        try sink.emit(.{ .done = .stop });
    }
};

const FlakyRun = struct {
    messages: usize,
    retries: usize,
    stop: proto.message.StopReason,
    /// Owned by std.testing.allocator.
    error_message: ?[]u8,
    /// Every assistant message points at the logged system entry.
    hashed: bool,
};

fn runFlaky(flaky: *Flaky, name: []const u8) !FlakyRun {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, name, "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("initial", "run", .queue);
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "flaky", .ctx = flaky, .stream = Flaky.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "", .retry = .{ .base_ms = 1, .cap_ms = 5 } },
    };
    try loop.run();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var retries: usize = 0;
    while (true) {
        const frame = (try sub.next(io)).?;
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, types.message_retry)) retries += 1;
        if (std.mem.eql(u8, event.type, types.agent_end)) break;
    }
    const msgs = session.messages.items;
    const last = msgs[msgs.len - 1];
    var hashed = true;
    for (msgs) |m| if (m.role == .assistant) {
        try std.testing.expect(m.completedAt.? >= m.timestamp);
        if (!std.mem.eql(u8, m.systemHash orelse "", session.system_hash.?)) hashed = false;
    };
    return .{
        .hashed = hashed,
        .messages = msgs.len,
        .retries = retries,
        .stop = last.stopReason.?,
        .error_message = if (last.errorMessage) |m| try std.testing.allocator.dupe(u8, m) else null,
    };
}

test "retryable failures before any output are retried with backoff" {
    var recovers: Flaky = .{ .failures = 2 };
    const ok = try runFlaky(&recovers, "ses_retry_ok");
    try std.testing.expectEqual(@as(usize, 3), recovers.calls);
    try std.testing.expectEqual(@as(usize, 2), ok.retries);
    try std.testing.expectEqual(@as(usize, 2), ok.messages);
    try std.testing.expectEqual(proto.message.StopReason.stop, ok.stop);

    var exhausted: Flaky = .{ .failures = 5 };
    const failed = try runFlaky(&exhausted, "ses_retry_exhausted");
    defer std.testing.allocator.free(failed.error_message.?);
    try std.testing.expectEqual(@as(usize, 3), exhausted.calls);
    try std.testing.expectEqual(proto.message.StopReason.@"error", failed.stop);
    try std.testing.expectEqualStrings("HTTP 503: overloaded", failed.error_message.?);
}

test "a failure after output is logged and retried as a new message" {
    var partial: Flaky = .{ .failures = 1, .partial = true };
    const result = try runFlaky(&partial, "ses_retry_partial");
    try std.testing.expectEqual(@as(usize, 2), partial.calls);
    try std.testing.expectEqual(@as(usize, 1), result.retries);
    // user, failed partial, recovered reply
    try std.testing.expectEqual(@as(usize, 3), result.messages);
    try std.testing.expectEqual(proto.message.StopReason.stop, result.stop);
    try std.testing.expect(result.hashed);
    // The retry never sent the failed partial back.
    try std.testing.expectEqual(@as(usize, 1), partial.most_messages);

    var exhausted: Flaky = .{ .failures = 5, .partial = true };
    const failed = try runFlaky(&exhausted, "ses_retry_partial_exhausted");
    defer std.testing.allocator.free(failed.error_message.?);
    try std.testing.expectEqual(@as(usize, 3), exhausted.calls);
    try std.testing.expectEqual(@as(usize, 4), failed.messages);
    try std.testing.expectEqual(proto.message.StopReason.@"error", failed.stop);
}

test "retry delay: exponential, capped, honours Retry-After, gives up on longer asks" {
    const retry: @import("loop.zig").Retry = .{};
    const busy: plugin.provider.Failure = .{ .message = "", .retryable = true };
    try std.testing.expectEqual(@as(?u64, 1000), retry.delay(busy, 1));
    try std.testing.expectEqual(@as(?u64, 2000), retry.delay(busy, 2));
    try std.testing.expectEqual(@as(?u64, null), retry.delay(busy, 3));
    try std.testing.expectEqual(@as(?u64, null), retry.delay(.{ .message = "" }, 1));
    try std.testing.expectEqual(@as(?u64, null), retry.delay(null, 1));
    var asked = busy;
    asked.retry_after_ms = 7000;
    try std.testing.expectEqual(@as(?u64, 7000), retry.delay(asked, 1));
    asked.retry_after_ms = 60_000;
    try std.testing.expectEqual(@as(?u64, null), retry.delay(asked, 1));
    const capped: @import("loop.zig").Retry = .{ .max_attempts = 10 };
    try std.testing.expectEqual(@as(?u64, 30_000), capped.delay(busy, 9));
}

test "canceled tool batch leaves no unpaired assistant tool call" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_tool_cancel", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("initial", "run", .queue);
    const Cancel = struct {
        fn stream(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) !void {
            try sink.emit(.{ .tool_call_start = .{ .index = 0, .id = "tool_canceled", .name = "cancel" } });
            try sink.emit(.{ .done = .tool_use });
        }
        fn execute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
            return error.Canceled;
        }
    };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "cancel", .stream = Cancel.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "", .executable_tools = &.{.{ .name = "cancel", .description = "", .input_schema = "{}", .execute = Cancel.execute }} },
    };
    try std.testing.expectError(error.Canceled, loop.run());
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
    try std.testing.expectEqualStrings("tool_canceled", session.messages.items[2].toolCallId.?);
    try std.testing.expect(session.messages.items[2].isError);
}
