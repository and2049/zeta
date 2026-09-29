//! JSON-RPC 2.0 over any MCP transport. A transport sends encoded messages
//! and hands every message it receives to `receive`; requests wait for their
//! response with a deadline, and a missed deadline or cancellation tells the
//! server with `notifications/cancelled`. Server requests are answered here
//! (`ping`, and what `Notice.request` handles; anything else is "method not
//! found").
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

/// Encodes as `{}`; an empty anonymous literal would encode as `[]`.
pub const empty: struct {} = .{};

/// Longest wait a request accepts; callers with their own deadline pass it.
pub const forever_ms: u64 = 7 * 24 * 60 * 60 * 1000;

/// Largest message accepted from a server.
pub const max_message = 16 * 1024 * 1024;

pub const Transport = struct {
    ctx: *anyopaque,
    /// Sends one message. May deliver messages to `receive` before returning.
    send: *const fn (ctx: *anyopaque, message: []const u8) anyerror!void,
    /// Sends a small message only if that cannot block; best effort. Null
    /// when the transport has no such way (then it is not sent).
    send_now: ?*const fn (ctx: *anyopaque, message: []const u8) void = null,
};

pub const Notice = struct {
    ctx: ?*anyopaque = null,
    /// A server notification: its method and params (borrowed for the
    /// call). Called on the transport's task.
    notify: ?*const fn (ctx: ?*anyopaque, method: []const u8, params: Value) void = null,
    /// The transport is gone. Called once, on the transport's task.
    closed: ?*const fn (ctx: ?*anyopaque, reason: []const u8) void = null,
    /// A server request other than `ping`, on the transport's task. True
    /// when it is handled: the handler answers with `Connection.reply`
    /// (it may do so later, with its own copy of `id`). Otherwise the
    /// method is not found.
    request: ?*const fn (ctx: ?*anyopaque, a: Allocator, id: Value, method: []const u8, params: Value) bool = null,
};

/// Error the server returned for a request.
pub const Remote = struct { code: i64, message: []const u8 };

const Waiter = struct {
    done: Io.Event = .unset,
    /// Raw JSON of `result`, or of `error`, owned by the connection's gpa.
    body: ?[]u8 = null,
    is_error: bool = false,
};

pub const Connection = struct {
    gpa: Allocator,
    io: Io,
    transport: Transport,
    notice: Notice = .{},
    mutex: Io.Mutex = .init,
    next_id: i64 = 1,
    waiters: std.AutoHashMapUnmanaged(i64, *Waiter) = .empty,
    /// Set once the transport is gone; every waiter is released.
    closed: ?[]const u8 = null,

    pub fn deinit(c: *Connection) void {
        c.waiters.deinit(c.gpa);
    }

    /// Sends `method` and waits for the result, which is parsed into `arena`.
    /// `params` must encode as an object (use `empty` for none).
    /// A server error is `error.McpRemoteError` with `remote` set.
    pub fn request(c: *Connection, arena: Allocator, method: []const u8, params: anytype, timeout_ms: u64, remote: ?*Remote) !Value {
        var waiter: Waiter = .{};
        const id = blk: {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            if (c.closed != null) return error.McpDisconnected;
            const id = c.next_id;
            c.next_id += 1;
            try c.waiters.put(c.gpa, id, &waiter);
            break :blk id;
        };
        defer {
            c.mutex.lockUncancelable(c.io);
            _ = c.waiters.remove(id);
            c.mutex.unlock(c.io);
            if (waiter.body) |body| c.gpa.free(body);
        }
        const message = try std.json.Stringify.valueAlloc(arena, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, .{});
        const Done = union(enum) { answered: anyerror!void, deadline: Io.Cancelable!void };
        var storage: [2]Done = undefined;
        var select: Io.Select(Done) = .init(c.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.answered, exchange, .{ c, message, &waiter });
        try select.concurrent(.deadline, Io.sleep, .{ c.io, Io.Duration.fromMilliseconds(@intCast(@min(timeout_ms, forever_ms))), Io.Clock.awake });
        // A request given up on is abandoned first (its exchange may be
        // blocked sending), then the server is told, if that cannot block.
        const outcome = select.await() catch |err| {
            select.cancelDiscard();
            if (err == error.Canceled) c.cancel(id, "canceled");
            return err;
        };
        switch (outcome) {
            .answered => |result| try result,
            .deadline => |result| {
                try result;
                select.cancelDiscard();
                c.cancel(id, "timed out");
                return error.McpTimeout;
            },
        }
        c.mutex.lockUncancelable(c.io);
        const body = waiter.body;
        const is_error = waiter.is_error;
        const reason = c.closed;
        c.mutex.unlock(c.io);
        const text = body orelse {
            std.log.warn("mcp: connection closed: {s}", .{reason orelse "unknown"});
            return error.McpDisconnected;
        };
        const value = try std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always });
        if (is_error) {
            if (remote) |out| out.* = .{
                .code = if (value == .object) switch (value.object.get("code") orelse .null) {
                    .integer => |i| i,
                    else => 0,
                } else 0,
                .message = if (value == .object) switch (value.object.get("message") orelse .null) {
                    .string => |s| s,
                    else => "",
                } else "",
            };
            return error.McpRemoteError;
        }
        return value;
    }

    fn exchange(c: *Connection, message: []const u8, waiter: *Waiter) anyerror!void {
        try c.transport.send(c.transport.ctx, message);
        try waiter.done.wait(c.io);
    }

    fn cancel(c: *Connection, id: i64, reason: []const u8) void {
        const now = c.transport.send_now orelse return;
        var buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{{\"requestId\":{d},\"reason\":\"{s}\"}}}}", .{ id, reason }) catch return;
        now(c.transport.ctx, message);
    }

    pub fn notify(c: *Connection, arena: Allocator, method: []const u8, params: anytype) !void {
        try c.transport.send(c.transport.ctx, try std.json.Stringify.valueAlloc(arena, .{ .jsonrpc = "2.0", .method = method, .params = params }, .{}));
    }

    /// Handles one message from the server (or a batch array of them).
    pub fn receive(c: *Connection, bytes: []const u8) void {
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const value = std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch {
            std.log.warn("mcp: ignored a message that is not JSON", .{});
            return;
        };
        switch (value) {
            .array => |items| for (items.items) |item| c.one(a, item),
            else => c.one(a, value),
        }
    }

    fn one(c: *Connection, a: Allocator, value: Value) void {
        if (value != .object) return;
        const o = value.object;
        const method: ?[]const u8 = switch (o.get("method") orelse .null) {
            .string => |s| s,
            else => null,
        };
        const id = o.get("id");
        if (method) |name| {
            if (id) |request_id| return c.answer(a, request_id, name, o.get("params") orelse .null);
            if (c.notice.notify) |f| f(c.notice.ctx, name, o.get("params") orelse .null);
            return;
        }
        const key = switch (id orelse return) {
            .integer => |i| i,
            else => return,
        };
        const payload, const is_error = if (o.get("result")) |r| .{ r, false } else if (o.get("error")) |e| .{ e, true } else return;
        const body = std.json.Stringify.valueAlloc(c.gpa, payload, .{}) catch return;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const waiter = c.waiters.get(key) orelse {
            c.gpa.free(body);
            return;
        };
        if (waiter.body != null) {
            c.gpa.free(body);
            return;
        }
        waiter.body = body;
        waiter.is_error = is_error;
        waiter.done.set(c.io);
    }

    fn answer(c: *Connection, a: Allocator, id: Value, method: []const u8, params: Value) void {
        if (std.mem.eql(u8, method, "ping")) return c.reply(a, id, empty);
        if (c.notice.request) |handle| if (handle(c.notice.ctx, a, id, method, params)) return;
        const message = std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32601, .message = "Method not found" } }, .{});
        c.transport.send(c.transport.ctx, message catch return) catch {};
    }

    /// Refuses the server's request `id` with a JSON-RPC error.
    pub fn replyError(c: *Connection, a: Allocator, id: Value, code: i64, message: []const u8) void {
        const text = std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{}) catch return;
        c.transport.send(c.transport.ctx, text) catch {};
    }

    /// Answers the server's request `id`.
    pub fn reply(c: *Connection, a: Allocator, id: Value, result: anytype) void {
        const message = std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{}) catch return;
        c.transport.send(c.transport.ctx, message) catch {};
    }

    /// The transport is gone: pending and later requests fail.
    pub fn close(c: *Connection, reason: []const u8) void {
        c.mutex.lockUncancelable(c.io);
        const first = c.closed == null;
        if (first) c.closed = reason;
        var it = c.waiters.valueIterator();
        while (it.next()) |waiter| waiter.*.done.set(c.io);
        c.mutex.unlock(c.io);
        if (first) if (c.notice.closed) |f| f(c.notice.ctx, reason);
    }
};

const testing = std.testing;

/// Answers every request at once, as a server on the other end would.
const Echo = struct {
    conn: *Connection = undefined,
    sent: std.ArrayList([]u8) = .empty,

    fn sendNow(ctx: *anyopaque, message: []const u8) void {
        const self: *Echo = @ptrCast(@alignCast(ctx));
        self.sent.append(testing.allocator, testing.allocator.dupe(u8, message) catch return) catch {};
    }

    fn send(ctx: *anyopaque, message: []const u8) anyerror!void {
        const self: *Echo = @ptrCast(@alignCast(ctx));
        try self.sent.append(testing.allocator, try testing.allocator.dupe(u8, message));
        const parsed = try std.json.parseFromSlice(Value, testing.allocator, message, .{});
        defer parsed.deinit();
        const id = parsed.value.object.get("id") orelse return;
        const method = (parsed.value.object.get("method") orelse return).string;
        var buf: [256]u8 = undefined;
        if (std.mem.eql(u8, method, "fail")) {
            self.conn.receive(try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32602,\"message\":\"bad\"}}}}", .{id.integer}));
        } else if (!std.mem.eql(u8, method, "slow")) {
            self.conn.receive(try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"echo\":\"{s}\"}}}}", .{ id.integer, method }));
        }
    }
};

test "requests get their results, server errors and deadlines; server pings are answered" {
    var echo: Echo = .{};
    defer {
        for (echo.sent.items) |m| testing.allocator.free(m);
        echo.sent.deinit(testing.allocator);
    }
    var conn: Connection = .{ .gpa = testing.allocator, .io = testing.io, .transport = .{ .ctx = &echo, .send = Echo.send, .send_now = Echo.sendNow } };
    defer conn.deinit();
    echo.conn = &conn;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try conn.request(a, "tools/list", empty, 1000, null);
    try testing.expectEqualStrings("tools/list", result.object.get("echo").?.string);
    var remote: Remote = undefined;
    try testing.expectError(error.McpRemoteError, conn.request(a, "fail", empty, 1000, &remote));
    try testing.expectEqual(@as(i64, -32602), remote.code);
    try testing.expectError(error.McpTimeout, conn.request(a, "slow", empty, 20, null));
    try testing.expect(std.mem.indexOf(u8, echo.sent.items[echo.sent.items.len - 1], "notifications/cancelled") != null);

    conn.receive("{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"ping\"}");
    try testing.expect(std.mem.indexOf(u8, echo.sent.items[echo.sent.items.len - 1], "\"id\":\"p1\",\"result\":{}") != null);
    conn.close("gone");
    try testing.expectError(error.McpDisconnected, conn.request(a, "tools/list", empty, 1000, null));
}
