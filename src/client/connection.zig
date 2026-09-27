//! Background SSE reader; UI polls owned frames without blocking on the network.
//! Commands use a separate Client instance (never share the reader's transport).
const std = @import("std");
const proto = @import("proto");
const Client = @import("Client.zig");
const attach = @import("attach.zig");
const api = @import("session_api.zig");
const Io = std.Io;
const A = std.mem.Allocator;

pub const Connection = struct {
    gpa: A,
    io: Io,
    options: attach.Options,
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    /// Protected by mutex. Worker unregisters before Request.deinit closes it.
    active: ?Io.net.Stream = null,
    stopping: bool = false,
    frames: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    /// Two maximum-size SSE frames can queue while the UI hydrates a snapshot.
    max_bytes: usize = 32 * 1024 * 1024,
    /// Each generation starts with server.connected. Discard the old projection
    /// and GET a snapshot before applying following frames.
    generation: u64 = 0,
    connected: bool = false,
    overflow: bool = false,

    pub fn init(gpa: A, io: Io, options: attach.Options) Connection {
        return .{ .gpa = gpa, .io = io, .options = options };
    }
    /// Must be called on a stable address. Stop before moving/destroying it.
    pub fn start(c: *Connection) !void {
        c.mutex.lockUncancelable(c.io);
        c.stopping = false;
        c.mutex.unlock(c.io);
        try c.group.concurrent(c.io, readLoop, .{c});
    }
    pub fn stop(c: *Connection) void {
        c.mutex.lockUncancelable(c.io);
        c.stopping = true;
        if (c.active) |socket| socket.shutdown(c.io, .both) catch {};
        c.mutex.unlock(c.io);
        c.group.cancel(c.io);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.clear();
        c.connected = false;
    }
    pub fn deinit(c: *Connection) void {
        c.stop();
        c.frames.deinit(c.gpa);
    }
    fn clear(c: *Connection) void {
        for (c.frames.items) |frame| c.gpa.free(frame);
        c.frames.clearRetainingCapacity();
        c.bytes = 0;
    }
    pub const Status = struct { generation: u64, connected: bool, overflow: bool };
    pub fn status(c: *Connection) Status {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return .{ .generation = c.generation, .connected = c.connected, .overflow = c.overflow };
    }
    /// Caller owns the returned bytes; free with the allocator passed to init.
    pub fn poll(c: *Connection) ?[]u8 {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (c.frames.items.len == 0) return null;
        const frame = c.frames.orderedRemove(0);
        c.bytes -= frame.len;
        return frame;
    }
    /// Synchronous action on an independent HTTP transport. The SSE task and
    /// its queue remain available to poll while this command is in flight.
    pub fn promptWithImages(c: *Connection, arena: A, session: []const u8, text: []const u8, delivery: api.Delivery, images: []const proto.attachment.Image) !api.Receipt {
        const d = try attach.attach(c.gpa, arena, c.io, c.options);
        var client = try Client.init(c.gpa, c.io, d.url, d.password);
        defer client.deinit();
        return api.promptWithImages(&client, arena, session, text, delivery, images);
    }
    fn push(c: *Connection, raw: []const u8, hello: bool) !void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (c.stopping) return error.Canceled;
        if (hello) {
            c.clear();
            c.generation += 1;
            c.connected = true;
            c.overflow = false;
        }
        if (raw.len + c.bytes > c.max_bytes) {
            c.clear();
            c.overflow = true;
            c.connected = false;
            return error.QueueOverflow;
        }
        try c.frames.append(c.gpa, try c.gpa.dupe(u8, raw));
        c.bytes += raw.len;
    }
    fn readLoop(c: *Connection) Io.Cancelable!void {
        while (true) {
            c.mutex.lockUncancelable(c.io);
            const stopping = c.stopping;
            c.mutex.unlock(c.io);
            if (stopping) return;
            var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena_state.deinit();
            c.readOnce(arena_state.allocator()) catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };
            c.mutex.lockUncancelable(c.io);
            c.connected = false;
            const closed = c.stopping;
            c.mutex.unlock(c.io);
            if (closed) return;
            try c.io.sleep(.fromMilliseconds(250), .awake);
        }
    }
    fn readOnce(c: *Connection, arena: A) !void {
        const d = try attach.attach(c.gpa, arena, c.io, c.options);
        var client = try Client.init(c.gpa, c.io, d.url, d.password);
        defer client.deinit();
        return c.consume(&client);
    }
    fn consume(c: *Connection, client: *Client) !void {
        const stream = try client.events();
        c.mutex.lockUncancelable(c.io);
        const closed = c.stopping;
        if (!closed) c.active = stream.socket();
        c.mutex.unlock(c.io);
        defer {
            c.mutex.lockUncancelable(c.io);
            if (!closed) c.active = null;
            c.mutex.unlock(c.io);
            stream.deinit(c.gpa);
        }
        if (closed) return error.Canceled;
        var event_arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer event_arena.deinit();
        const first = (try stream.next(event_arena.allocator())) orelse return error.StreamClosed;
        if (!std.mem.eql(u8, first.event.type, proto.event.types.server_connected)) return error.BadHandshake;
        try c.push(first.raw, true);
        while (true) {
            _ = event_arena.reset(.retain_capacity);
            const next = (try stream.next(event_arena.allocator())) orelse return error.StreamClosed;
            try c.push(next.raw, false);
        }
    }
};

const IdleFixture = struct {
    listener: Io.net.Server,
    ready: Io.Event = .unset,
    response: []const u8,

    fn serve(f: *IdleFixture, io: Io) Io.Cancelable!void {
        const stream = f.listener.accept(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        defer stream.close(io);
        var buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &buf);
        writer.interface.writeAll(f.response) catch return Io.checkCancel(io);
        writer.interface.flush() catch return Io.checkCancel(io);
        f.ready.set(io);
        // Deliberately withhold both the next SSE frame and EOF.
        try io.sleep(.fromSeconds(2), .awake);
    }
    fn read(c: *Connection, url: []const u8) Io.Cancelable!void {
        var client = Client.init(c.gpa, c.io, url, "pw") catch return;
        defer client.deinit();
        c.consume(&client) catch |err| {
            if (err == error.Canceled) return error.Canceled;
        };
    }
};

const ReconnectFixture = struct {
    listener: Io.net.Server,
    hello: []const u8,

    fn serve(f: *ReconnectFixture, io: Io) Io.Cancelable!void {
        // First generation ends immediately; the second remains silent.
        for (0..2) |n| {
            const stream = f.listener.accept(io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                return;
            };
            var buf: [1024]u8 = undefined;
            var writer = stream.writer(io, &buf);
            writer.interface.writeAll(f.hello) catch return Io.checkCancel(io);
            if (n == 0) writer.interface.writeAll("0\r\n\r\n") catch return Io.checkCancel(io);
            writer.interface.flush() catch return Io.checkCancel(io);
            if (n == 0) {
                stream.close(io);
            } else {
                defer stream.close(io);
                try io.sleep(.fromSeconds(2), .awake);
            }
        }
    }
    fn read(c: *Connection, url: []const u8) Io.Cancelable!void {
        for (0..2) |_| {
            var client = Client.init(c.gpa, c.io, url, "pw") catch return;
            c.consume(&client) catch |err| {
                if (err == error.Canceled) {
                    client.deinit();
                    return error.Canceled;
                }
            };
            client.deinit();
        }
    }
};

test "bounded queue and generation handshake" {
    var c = Connection.init(std.testing.allocator, std.testing.io, .{ .paths = undefined, .exe = "" });
    defer {
        c.clear();
        c.frames.deinit(c.gpa);
    }
    c.max_bytes = 8;
    try c.push("hello", true);
    try std.testing.expectEqual(@as(u64, 1), c.status().generation);
    try std.testing.expectError(error.QueueOverflow, c.push("overflow", false));
    try std.testing.expect(c.poll() == null);
    try c.push("new", true);
    const frame = c.poll().?;
    defer c.gpa.free(frame);
    try std.testing.expectEqualStrings("new", frame);
    try std.testing.expectEqual(@as(u64, 2), c.status().generation);
}

test "default queue admits a valid image-sized frame" {
    var c = Connection.init(std.testing.allocator, std.testing.io, .{ .paths = undefined, .exe = "" });
    defer {
        c.clear();
        c.frames.deinit(c.gpa);
    }
    const frame = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(frame);
    @memset(frame, 'a');
    try c.push("hello", true);
    try c.push(frame, false);
    try std.testing.expect(!c.status().overflow);
    const hello = c.poll().?;
    c.gpa.free(hello);
    const received = c.poll().?;
    defer c.gpa.free(received);
    try std.testing.expectEqual(frame.len, received.len);
}

test "idle SSE stop joins without waiting for server heartbeat" {
    const io = std.testing.io;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    const envelope = "{\"seq\":0,\"type\":\"server.connected\",\"time\":1,\"data\":{}}";
    const frame = try std.fmt.allocPrint(std.testing.allocator, "data: {s}\n\n", .{envelope});
    defer std.testing.allocator.free(frame);
    const response = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{x}\r\n{s}\r\n", .{ frame.len, frame });
    defer std.testing.allocator.free(response);
    var fixture: IdleFixture = .{ .listener = try addr.listen(io, .{}), .response = response };
    defer fixture.listener.deinit(io);
    var server: Io.Group = .init;
    defer server.cancel(io);
    try server.concurrent(io, IdleFixture.serve, .{ &fixture, io });
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{fixture.listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var c = Connection.init(std.testing.allocator, io, .{ .paths = undefined, .exe = "" });
    defer c.deinit();
    try c.group.concurrent(io, IdleFixture.read, .{ &c, url });
    try fixture.ready.wait(io);
    const deadline = Io.Clock.awake.now(io).toMilliseconds() + 1000;
    while (!c.status().connected and Io.Clock.awake.now(io).toMilliseconds() < deadline) try io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(c.status().connected);
    const started = Io.Clock.awake.now(io).toMilliseconds();
    c.stop();
    try std.testing.expect(Io.Clock.awake.now(io).toMilliseconds() - started < 800);
}

test "stop after reconnect closes the current generation, not the old socket" {
    const io = std.testing.io;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    const frame = "data: {\"seq\":0,\"type\":\"server.connected\",\"time\":1,\"data\":{}}\n\n";
    const response = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{x}\r\n{s}\r\n", .{ frame.len, frame });
    defer std.testing.allocator.free(response);
    var fixture: ReconnectFixture = .{ .listener = try addr.listen(io, .{}), .hello = response };
    defer fixture.listener.deinit(io);
    var server: Io.Group = .init;
    defer server.cancel(io);
    try server.concurrent(io, ReconnectFixture.serve, .{ &fixture, io });
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{fixture.listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var c = Connection.init(std.testing.allocator, io, .{ .paths = undefined, .exe = "" });
    defer c.deinit();
    try c.group.concurrent(io, ReconnectFixture.read, .{ &c, url });
    const deadline = Io.Clock.awake.now(io).toMilliseconds() + 1000;
    while (c.status().generation < 2 and Io.Clock.awake.now(io).toMilliseconds() < deadline) try io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expectEqual(@as(u64, 2), c.status().generation);
    const started = Io.Clock.awake.now(io).toMilliseconds();
    c.stop();
    try std.testing.expect(Io.Clock.awake.now(io).toMilliseconds() - started < 800);
    try std.testing.expect(c.active == null);
}
