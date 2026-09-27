//! In-process, loopback-only OAuth issuer fixture. Imported by tests only.
const std = @import("std");
const Io = std.Io;

pub const Fixture = struct {
    listener: Io.net.Server,
    mutex: Io.Mutex = .init,
    calls: usize = 0,
    pending: usize = 0,
    token_body: []const u8 = "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"a.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0In0.b\",\"expires_in\":3600}",
    token_encoding: enum { identity, gzip, deflate } = .identity,
    request_body: [4096]u8 = undefined,
    request_len: usize = 0,
    stalled: bool = false,
    entered: Io.Event = .unset,

    pub fn init(io: Io) !Fixture {
        const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .listener = try addr.listen(io, .{}) };
    }

    pub fn url(self: *Fixture, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.listener.socket.address.getPort()});
    }

    pub fn serve(self: *Fixture, io: Io) Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                return;
            };
            defer stream.close(io);
            var recv: [8192]u8 = undefined;
            var send: [8192]u8 = undefined;
            var reader = stream.reader(io, &recv);
            var writer = stream.writer(io, &send);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var req = server.receiveHead() catch continue;
            const target = req.head.target;
            var body: [4096]u8 = undefined;
            const body_reader = req.readerExpectContinue(&body) catch continue;
            const input = body_reader.allocRemaining(std.testing.allocator, .limited(4096)) catch continue;
            defer std.testing.allocator.free(input);
            self.mutex.lockUncancelable(io);
            self.calls += 1;
            self.request_len = @min(input.len, self.request_body.len);
            @memcpy(self.request_body[0..self.request_len], input[0..self.request_len]);
            const should_wait = self.stalled;
            const pending = self.pending;
            if (std.mem.eql(u8, target, "/api/accounts/deviceauth/token") and pending > 0) self.pending -= 1;
            self.mutex.unlock(io);
            if (should_wait) {
                self.entered.set(io);
                io.sleep(.fromSeconds(60), .awake) catch |err| return err;
            }
            if (std.mem.eql(u8, target, "/api/accounts/deviceauth/usercode")) {
                req.respond("{\"device_auth_id\":\"device-id\",\"user_code\":\"ABCD\",\"interval\":\"1\"}", .{}) catch return Io.checkCancel(io);
            } else if (std.mem.eql(u8, target, "/api/accounts/deviceauth/token")) {
                if (pending > 0) req.respond("", .{ .status = .forbidden }) catch return Io.checkCancel(io) else req.respond("{\"authorization_code\":\"device-code\",\"code_verifier\":\"verifier\"}", .{}) catch return Io.checkCancel(io);
            } else if (std.mem.eql(u8, target, "/oauth/token")) {
                self.respondToken(&req) catch return Io.checkCancel(io);
            } else {
                req.respond("", .{ .status = .not_found }) catch return Io.checkCancel(io);
            }
        }
    }

    fn respondToken(self: *Fixture, req: *std.http.Server.Request) !void {
        if (self.token_encoding == .identity) return req.respond(self.token_body, .{});
        var encoded: [4096]u8 = undefined;
        var output = Io.Writer.fixed(&encoded);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(&output, &window, if (self.token_encoding == .gzip) .gzip else .zlib, .default);
        try compress.writer.writeAll(self.token_body);
        try compress.finish();
        try req.respond(output.buffered(), .{ .extra_headers = &.{.{ .name = "content-encoding", .value = @tagName(self.token_encoding) }} });
    }

    pub fn snapshot(self: *Fixture, io: Io, a: std.mem.Allocator) !struct { calls: usize, body: []const u8 } {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{ .calls = self.calls, .body = try a.dupe(u8, self.request_body[0..self.request_len]) };
    }
};
