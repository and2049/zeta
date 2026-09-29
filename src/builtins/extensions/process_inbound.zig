//! Reads extension lines and routes registration, events, responses, and calls.
const std = @import("std");
const Process = @import("Process.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const Message = Process.Message;
const max_line = Process.max_line;

pub fn readLoop(p: *Process, file: Io.File) Io.Cancelable!void {
    defer file.close(p.io);
    const reason = try lines(p, file);
    p.mutex.lockUncancelable(p.io);
    const quiet = p.stopping;
    if (p.gone == null) p.gone = reason;
    p.mutex.unlock(p.io);
    p.closeWaiters(reason);
    p.registered.set(p.io);
    if (!quiet) p.lost.lost(p.lost.ctx, reason);
}

fn lines(p: *Process, file: Io.File) Io.Cancelable![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(p.gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(p.io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => return "the extension exited",
            error.Canceled => return error.Canceled,
            else => return "reading from the extension failed",
        };
        if (n == 0) return "the extension exited";
        var rest = chunk[0..n];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |end| {
            appendSegment(&line, p.gpa, rest[0..end]) catch |err| return if (err == error.MessageTooLarge) "a message was too large" else "out of memory";
            const text = std.mem.trim(u8, line.items, " \t\r");
            if (text.len > 0) if (handle(p, text)) |problem| return problem;
            line.clearRetainingCapacity();
            rest = rest[end + 1 ..];
        }
        appendSegment(&line, p.gpa, rest) catch |err| return if (err == error.MessageTooLarge) "a message was too large" else "out of memory";
    }
}

fn appendSegment(line: *std.ArrayList(u8), allocator: Allocator, segment: []const u8) !void {
    if (segment.len > max_line - line.items.len) return error.MessageTooLarge;
    try line.appendSlice(allocator, segment);
}

test "newline-terminated extension messages respect the line limit" {
    const a = std.testing.allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    const prefix = try a.alloc(u8, max_line - 2);
    defer a.free(prefix);
    @memset(prefix, 'x');
    try appendSegment(&line, a, prefix);
    try appendSegment(&line, a, "ok");
    try std.testing.expectError(error.MessageTooLarge, appendSegment(&line, a, "\n"));
    try std.testing.expectEqual(@as(usize, max_line), line.items.len);
}

/// Dispatches one message; returns a reason to stop reading.
pub fn handle(p: *Process, text: []const u8) ?[]const u8 {
    p.last_seen.store(Io.Clock.awake.now(p.io).toMilliseconds(), .monotonic);
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const value = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch return "a message was not JSON";
    if (value != .object) return "a message was not a JSON object";
    const o = value.object;
    const kind = switch (o.get("type") orelse .null) {
        .string => |t| t,
        else => return "a message had no type",
    };
    p.mutex.lockUncancelable(p.io);
    const first = p.registration == null;
    p.mutex.unlock(p.io);
    if (first) {
        if (!std.mem.eql(u8, kind, "register")) return "the first message was not register";
        const copy = p.gpa.dupe(u8, text) catch return "out of memory";
        p.mutex.lockUncancelable(p.io);
        p.registration = copy;
        p.mutex.unlock(p.io);
        p.registered.set(p.io);
        return null;
    }
    if (std.mem.eql(u8, kind, "pong")) return null;
    if (std.mem.eql(u8, kind, "call")) {
        const copy = p.gpa.dupe(u8, text) catch return "out of memory";
        p.call_tasks.concurrent(p.io, answerCall, .{ p, copy }) catch p.gpa.free(copy);
        return null;
    }
    const is_event = std.mem.eql(u8, kind, "event");
    if (!is_event and !std.mem.eql(u8, kind, "response")) return "a message had an unknown type";
    const id = switch (o.get("id") orelse .null) {
        .string => |s| s,
        else => return "a response had no id",
    };
    var message: Message = .{ .kind = if (is_event) .event else .response, .body = undefined };
    const payload: Value = if (is_event) o.get("event") orelse .null else if (o.get("error")) |e| blk: {
        message.is_error = true;
        message.retryable = if (o.get("retryable")) |r| r == .bool and r.bool else false;
        message.overflow = if (o.get("overflow")) |r| r == .bool and r.bool else false;
        break :blk e;
    } else o.get("result") orelse .null;
    message.body = std.json.Stringify.valueAlloc(p.gpa, payload, .{}) catch return "out of memory";
    // The waiter is pinned so its request cannot free it mid-delivery.
    const target = blk: {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const w = p.waiters.get(id) orelse break :blk null;
        _ = w.refs.fetchAdd(1, .acq_rel);
        break :blk w;
    } orelse {
        p.gpa.free(message.body);
        return null;
    };
    defer p.release(target);
    target.queue.putOneUncancelable(p.io, message) catch p.gpa.free(message.body);
    return null;
}

fn answerCall(p: *Process, text: []u8) Io.Cancelable!void {
    defer p.gpa.free(text);
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const value = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch return;
    const id = value.object.get("id") orelse return;
    const method = switch (value.object.get("method") orelse .null) {
        .string => |m| m,
        else => "",
    };
    const reply = if (p.calls.answer(p.calls.ctx, a, p.io, method, value.object.get("params") orelse .null)) |result|
        std.fmt.allocPrint(a, "{{\"type\":\"result\",\"id\":{f},\"result\":{s}}}", .{ std.json.fmt(id, .{}), result })
    else |err| blk: {
        if (err == error.Canceled) return error.Canceled;
        break :blk std.json.Stringify.valueAlloc(a, .{ .type = "result", .id = id, .@"error" = @errorName(err) }, .{});
    };
    p.send(reply catch return) catch {};
}
