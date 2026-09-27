//! Recovers the specific error behind std.http's generic `ReadFailed` and
//! `WriteFailed`. A worker canceled mid-request surfaces as `ReadFailed`
//! from the body reader; callers must see `error.Canceled` to record an
//! abort instead of a provider failure.
const std = @import("std");

pub fn of(req: *const std.http.Client.Request, err: anyerror) anyerror {
    const conn = req.connection orelse return err;
    switch (err) {
        error.ReadFailed => {
            if (conn.stream_reader.err) |cause| return cause;
            if (req.reader.body_err) |cause| return cause;
        },
        error.WriteFailed => if (conn.stream_writer.err) |cause| return cause,
        else => {},
    }
    return err;
}

/// A failed error-body read loses its detail, unless the request was canceled.
pub fn errorBody(arena: std.mem.Allocator, req: *const std.http.Client.Request, reader: *std.Io.Reader, limit: usize) ![]const u8 {
    return reader.allocRemaining(arena, .limited(limit)) catch |err| {
        if (of(req, err) == error.Canceled) return error.Canceled;
        return "";
    };
}

test "a canceled body read surfaces as Canceled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const Stall = struct {
        fn serve(listener: *std.Io.net.Server, stall_io: std.Io) std.Io.Cancelable!void {
            const stream = listener.accept(stall_io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            defer stream.close(stall_io);
            var buf: [1024]u8 = undefined;
            var reader = stream.reader(stall_io, &buf);
            var out_buf: [256]u8 = undefined;
            var writer = stream.writer(stall_io, &out_buf);
            var http: std.http.Server = .init(&reader.interface, &writer.interface);
            _ = http.receiveHead() catch return;
            // Send the head, then never the body.
            writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n") catch return;
            writer.interface.flush() catch return;
            try stall_io.sleep(.fromSeconds(5), .awake);
        }
        fn fetch(fetch_io: std.Io, a: std.mem.Allocator, url_port: u16) !void {
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            var client: std.http.Client = .{ .allocator = arena.allocator(), .io = fetch_io };
            defer client.deinit();
            const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/", .{url_port});
            var req = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
            defer {
                if (req.connection) |connection| connection.closing = true;
                req.deinit();
            }
            try req.sendBodiless();
            var response = try req.receiveHead(&.{});
            var transfer: [64]u8 = undefined;
            const body = response.reader(&transfer);
            _ = body.takeByte() catch |err| return of(&req, err);
            return error.UnexpectedBody;
        }
    };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Stall.serve, .{ &server, io });
    var fetching = try io.concurrent(Stall.fetch, .{ io, gpa, port });
    try io.sleep(.fromMilliseconds(100), .awake);
    try std.testing.expectError(error.Canceled, fetching.cancel(io));
}
