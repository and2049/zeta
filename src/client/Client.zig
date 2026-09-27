const Client = @This();

const std = @import("std");
const proto = @import("proto");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;

gpa: Allocator,
io: Io,
transport: http.Client,
base_url: []const u8,
auth_buf: [256]u8 = undefined,
auth_len: usize = 0,

/// `base_url` must outlive the client.
pub fn init(gpa: Allocator, io: Io, base_url: []const u8, password: []const u8) !Client {
    var c: Client = .{
        .gpa = gpa,
        .io = io,
        .transport = .{ .allocator = gpa, .io = io },
        .base_url = base_url,
    };
    c.auth_len = (try proto.discovery.authHeader(&c.auth_buf, password)).len;
    return c;
}

pub fn deinit(c: *Client) void {
    c.transport.deinit();
}

fn authorization(c: *const Client) []const u8 {
    return c.auth_buf[0..c.auth_len];
}

pub const Response = struct {
    status: http.Status,
    body: []u8,

    pub fn ok(r: Response) bool {
        return r.status.class() == .success;
    }
};

pub fn get(c: *Client, arena: Allocator, path: []const u8) !Response {
    return c.call(arena, .GET, path, null);
}

pub fn postJson(c: *Client, arena: Allocator, path: []const u8, value: anytype) !Response {
    const payload = try std.json.Stringify.valueAlloc(arena, value, .{});
    return c.call(arena, .POST, path, payload);
}

pub fn putJson(c: *Client, arena: Allocator, path: []const u8, value: anytype) !Response {
    const payload = try std.json.Stringify.valueAlloc(arena, value, .{});
    return c.call(arena, .PUT, path, payload);
}

pub fn patchJson(c: *Client, arena: Allocator, path: []const u8, value: anytype) !Response {
    const payload = try std.json.Stringify.valueAlloc(arena, value, .{});
    return c.call(arena, .PATCH, path, payload);
}

pub fn delete(c: *Client, arena: Allocator, path: []const u8) !Response {
    return c.call(arena, .DELETE, path, null);
}

fn call(c: *Client, arena: Allocator, method: http.Method, path: []const u8, payload: ?[]const u8) !Response {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ c.base_url, path });
    const uri = try std.Uri.parse(url);
    var body: Io.Writer.Allocating = .init(arena);
    // std.http.Client.fetch owns its Request internally. Its defer deinit
    // drains an unfinished response even when the caller was cancelled; on
    // teardown that can wait for a delayed server response. Own the request
    // here and always close rather than drain the one-shot connection.
    var req = try c.transport.request(method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = c.authorization() },
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
        },
    });
    defer {
        if (req.connection) |connection| connection.closing = true;
        req.deinit();
    }
    if (payload) |bytes| {
        req.transfer_encoding = .{ .content_length = bytes.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(bytes);
        try writer.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();
    var response = req.receiveHead(&.{}) catch |err| {
        try Io.checkCancel(c.io);
        return err;
    };
    const status = response.head.status;
    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    _ = reader.streamRemaining(&body.writer) catch |err| {
        try Io.checkCancel(c.io);
        return err;
    };
    return .{ .status = status, .body = body.written() };
}

pub const EventStream = struct {
    req: http.Client.Request,
    body: *Io.Reader,
    transfer_buf: [16 * 1024]u8,
    decoder: proto.sse.Decoder,

    /// Borrowed socket value. Caller must synchronize its use with deinit;
    /// shutdown wakes a blocked SSE read without closing/freeing the request.
    pub fn socket(s: *const EventStream) Io.net.Stream {
        return s.req.connection.?.stream_reader.stream;
    }

    pub const Frame = struct {
        /// The raw envelope JSON; valid until the next call.
        raw: []const u8,
        event: proto.event.Decoded,
    };

    /// Next envelope, parsed into `arena`. Null when the server ends the stream.
    pub fn next(s: *EventStream, arena: Allocator) !?Frame {
        const ev = (try s.decoder.next(s.body)) orelse return null;
        return .{ .raw = ev.data, .event = try proto.event.Decoded.parse(arena, ev.data) };
    }

    pub fn deinit(s: *EventStream, gpa: Allocator) void {
        s.decoder.deinit();
        // SSE is an intentionally endless response. Request.deinit normally
        // drains an unread body to reuse its connection; that can block until
        // the next heartbeat even after the reader task was cancelled.
        // This request uses keep_alive=false, so discard the connection now.
        if (s.req.connection) |connection| connection.closing = true;
        s.req.deinit();
        gpa.destroy(s);
    }
};

/// Opens the SSE feed. Heap-allocated so the reader's internal pointers stay put.
pub fn events(c: *Client) !*EventStream {
    const url = try std.fmt.allocPrint(c.gpa, "{s}/event", .{c.base_url});
    defer c.gpa.free(url);
    const uri = try std.Uri.parse(url);

    const s = try c.gpa.create(EventStream);
    errdefer c.gpa.destroy(s);
    s.req = try c.transport.request(.GET, uri, .{
        .keep_alive = false,
        .headers = .{ .authorization = .{ .override = c.authorization() } },
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
    });
    errdefer {
        if (s.req.connection) |connection| connection.closing = true;
        s.req.deinit();
    }
    try s.req.sendBodiless();
    var response = try s.req.receiveHead(&.{});
    if (response.head.status != .ok) return error.EventStreamRejected;
    s.body = response.reader(&s.transfer_buf);
    s.decoder = .init(c.gpa);
    return s;
}

const SlowResponse = struct {
    listener: Io.net.Server,
    ready: Io.Event = .unset,

    fn serve(s: *SlowResponse, io: Io) Io.Cancelable!void {
        const stream = s.listener.accept(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        defer stream.close(io);
        var buf: [512]u8 = undefined;
        var writer = stream.writer(io, &buf);
        writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\nx") catch return Io.checkCancel(io);
        writer.interface.flush() catch return Io.checkCancel(io);
        s.ready.set(io);
        try io.sleep(.fromSeconds(2), .awake);
    }
    fn read(io: Io, url: []const u8) Io.Cancelable!void {
        var c = Client.init(std.testing.allocator, io, url, "pw") catch return;
        defer c.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        _ = c.get(arena.allocator(), "/health") catch |err| {
            if (err == error.Canceled) return error.Canceled;
        };
    }
};

test "canceled ordinary HTTP request does not drain a stalled response" {
    const io = std.testing.io;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var fixture: SlowResponse = .{ .listener = try addr.listen(io, .{}) };
    defer fixture.listener.deinit(io);
    var server: Io.Group = .init;
    defer server.cancel(io);
    try server.concurrent(io, SlowResponse.serve, .{ &fixture, io });
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{fixture.listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var caller: Io.Group = .init;
    defer caller.cancel(io);
    try caller.concurrent(io, SlowResponse.read, .{ io, url });
    try fixture.ready.wait(io);
    const started = Io.Clock.awake.now(io).toMilliseconds();
    caller.cancel(io);
    try std.testing.expect(Io.Clock.awake.now(io).toMilliseconds() - started < 800);
}
