//! Loopback tests for connection reuse in `http_pool.zig`.
const std = @import("std");
const Io = std.Io;
const http_pool = @import("http_pool.zig");

const Fixture = struct {
    listener: Io.net.Server,
    /// Requests answered on one connection before the server closes it.
    per_connection: usize = 8,
    /// Answer with a chunked body that never ends.
    open_ended: bool = false,
    /// What to send, then close, instead of every response after the first
    /// on a connection.
    cut_later: ?[]const u8 = null,
    accepts: usize = 0,
    url: [64]u8 = undefined,

    fn serve(f: *Fixture, io: Io) Io.Cancelable!void {
        while (true) {
            const stream = f.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            defer stream.close(io);
            f.accepts += 1;
            try f.answer(io, stream);
        }
    }

    fn answer(f: *Fixture, io: Io, stream: Io.net.Stream) Io.Cancelable!void {
        var input: [4096]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = stream.reader(io, &input);
        var writer = stream.writer(io, &output);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);
        for (0..f.per_connection) |i| {
            var req = server.receiveHead() catch return;
            var body: [256]u8 = undefined;
            _ = (req.readerExpectNone(&body)).discardRemaining() catch return;
            if (f.open_ended) {
                writer.interface.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n") catch return;
                writer.interface.flush() catch return;
                // Until the client gives up on the connection.
                _ = reader.interface.discardRemaining() catch {};
                return;
            }
            if (f.cut_later) |cut| if (i > 0) {
                writer.interface.writeAll(cut) catch return;
                writer.interface.flush() catch return;
                return;
            };
            writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello") catch return;
            writer.interface.flush() catch return;
        }
    }
};

fn start(f: *Fixture) !std.Uri {
    const port = f.listener.socket.address.getPort();
    return std.Uri.parse(try std.fmt.bufPrint(&f.url, "http://127.0.0.1:{d}/v1", .{port}));
}

fn exchange(pool: *http_pool.Pool, uri: std.Uri) ![]const u8 {
    var lease: http_pool.Lease = undefined;
    var response = try http_pool.post(pool, &lease, uri, .{}, "{}");
    defer lease.release();
    var buf: [64]u8 = undefined;
    const reader = response.reader(&buf);
    const got = try reader.take(5);
    try std.testing.expectEqualStrings("hello", got);
    lease.finish(reader);
    return if (lease.reusable) "reused" else "closed";
}

fn listen(io: Io) !Io.net.Server {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    return addr.listen(io, .{});
}

test "requests share one connection" {
    const io = std.testing.io;
    var f: Fixture = .{ .listener = try listen(io) };
    defer f.listener.deinit(io);
    var server = try io.concurrent(Fixture.serve, .{ &f, io });
    defer server.cancel(io) catch {};
    const uri = try start(&f);
    var pool: http_pool.Pool = .init(std.testing.allocator, io);
    defer pool.deinit();
    for (0..3) |_| try std.testing.expectEqualStrings("reused", try exchange(&pool, uri));
    try std.testing.expectEqual(1, f.accepts);
}

test "a pooled connection the server closed is retried on a new one" {
    const io = std.testing.io;
    var f: Fixture = .{ .listener = try listen(io), .per_connection = 1 };
    defer f.listener.deinit(io);
    var server = try io.concurrent(Fixture.serve, .{ &f, io });
    defer server.cancel(io) catch {};
    const uri = try start(&f);
    var pool: http_pool.Pool = .init(std.testing.allocator, io);
    defer pool.deinit();
    _ = try exchange(&pool, uri);
    _ = try exchange(&pool, uri);
    try std.testing.expectEqual(2, f.accepts);
}

test "idle connections are dropped" {
    const io = std.testing.io;
    var f: Fixture = .{ .listener = try listen(io) };
    defer f.listener.deinit(io);
    var server = try io.concurrent(Fixture.serve, .{ &f, io });
    defer server.cancel(io) catch {};
    const uri = try start(&f);
    var pool: http_pool.Pool = .init(std.testing.allocator, io);
    defer pool.deinit();
    pool.idle_ms = -1;
    _ = try exchange(&pool, uri);
    _ = try exchange(&pool, uri);
    try std.testing.expectEqual(2, f.accepts);
}

test "a response that stays open closes its connection, and later ones are not drained" {
    const io = std.testing.io;
    var f: Fixture = .{ .listener = try listen(io), .open_ended = true };
    defer f.listener.deinit(io);
    var server = try io.concurrent(Fixture.serve, .{ &f, io });
    defer server.cancel(io) catch {};
    const uri = try start(&f);
    var pool: http_pool.Pool = .init(std.testing.allocator, io);
    defer pool.deinit();
    pool.drain_ms = 200;
    try std.testing.expectEqualStrings("closed", try exchange(&pool, uri));
    const started = Io.Clock.awake.now(io).toMilliseconds();
    try std.testing.expectEqualStrings("closed", try exchange(&pool, uri));
    try std.testing.expect(Io.Clock.awake.now(io).toMilliseconds() - started < 150);
    try std.testing.expectEqual(2, f.accepts);
}

test "a pooled request whose response started is not sent again" {
    const io = std.testing.io;
    for ([_]struct { cut: []const u8, err: anyerror }{
        .{ .cut = "HTTP/1.1 200 OK\r\nContent-Le", .err = error.HttpRequestTruncated },
        .{ .cut = "HTTP/1.1 100 Continue\r\n\r\n", .err = error.HttpConnectionClosing },
    }) |case| {
        var f: Fixture = .{ .listener = try listen(io), .cut_later = case.cut };
        defer f.listener.deinit(io);
        var server = try io.concurrent(Fixture.serve, .{ &f, io });
        defer server.cancel(io) catch {};
        const uri = try start(&f);
        var pool: http_pool.Pool = .init(std.testing.allocator, io);
        defer pool.deinit();
        try std.testing.expectEqualStrings("reused", try exchange(&pool, uri));
        try std.testing.expectError(case.err, exchange(&pool, uri));
        try std.testing.expectEqual(1, f.accepts);
    }
}
