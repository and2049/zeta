const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const auth = @import("auth.zig");
const limits = @import("limits.zig");

pub const max_body = 8 * 1024 * 1024;

/// What a handler sees. Strings are copied into `arena` before the body is
/// read, so they stay valid for the whole request.
pub const Ctx = struct {
    io: Io,
    arena: Allocator,
    method: http.Method,
    path: []const u8,
    query: []const u8,
    req: *http.Server.Request,
    /// Deadline slot of this connection; null in handler tests.
    slot: ?*limits.Slot = null,
    body_read: bool = false,
    body_complete: bool = false,
    responded: bool = false,

    /// Reads the whole request body (bounded by `max_body`).
    pub fn body(c: *Ctx) ![]const u8 {
        std.debug.assert(!c.body_read);
        c.body_read = true;
        if (!c.hasBody()) return "";
        var buf: [4096]u8 = undefined;
        const r = try c.req.readerExpectContinue(&buf);
        const bytes = r.allocRemaining(c.arena, .limited(max_body)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooLarge,
            else => |e| return e,
        };
        c.body_complete = true;
        if (c.slot) |slot| slot.unbounded();
        return bytes;
    }

    pub fn bodyJson(c: *Ctx, comptime T: type) !T {
        const bytes = try c.body();
        return std.json.parseFromSliceLeaky(T, c.arena, if (bytes.len == 0) "{}" else bytes, .{
            .allocate = .alloc_always,
        });
    }

    pub fn json(c: *Ctx, status: http.Status, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(c.arena, value, .{});
        try c.send(status, "application/json", bytes);
    }

    pub fn fail(c: *Ctx, status: http.Status, message: []const u8) !void {
        try c.json(status, .{ .@"error" = message });
    }

    pub fn send(c: *Ctx, status: http.Status, content_type: []const u8, bytes: []const u8) !void {
        c.responded = true;
        try c.req.respond(bytes, .{
            .status = status,
            .keep_alive = c.canKeepAlive(),
            .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
        });
    }

    /// Starts a streaming response. Caller writes to the returned body and
    /// calls `end` on it.
    pub fn stream(c: *Ctx, buf: []u8, content_type: []const u8) !http.BodyWriter {
        c.responded = true;
        return c.req.respondStreaming(buf, .{ .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        } });
    }

    fn hasBody(c: *const Ctx) bool {
        return framedBody(c.req);
    }

    /// std.http asserts on a keep-alive response to a body-method request
    /// that declared no length, so close those connections instead. A body
    /// that was only partly read (too large, read error) leaves unread bytes
    /// that would be parsed as the next request, so close those too. An
    /// unread body is discarded by std.http before the connection is reused.
    fn canKeepAlive(c: *const Ctx) bool {
        if (c.method.requestHasBody() and !c.hasBody()) return false;
        return !c.body_read or c.body_complete;
    }
};

pub const Handler = *const fn (userdata: *anyopaque, c: *Ctx) anyerror!void;

/// Owns `stream` and `slot`: releases the slot, then closes the stream.
pub fn serve(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    slot: *limits.Slot,
    password: []const u8,
    userdata: *anyopaque,
    handler: Handler,
) void {
    defer {
        slot.tracker.release(slot);
        var copy = stream;
        copy.close(io);
    }
    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var server: http.Server = .init(&reader.interface, &writer.interface);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // The first request is bounded from accept by the header deadline. Later
    // ones may idle until their first byte, then get the same header bound.
    var first = true;
    while (true) : (first = false) {
        _ = arena.reset(.retain_capacity);
        if (!first) {
            slot.waitRequest();
            reader.interface.fill(1) catch return;
            slot.readHeaders();
        }
        var req = server.receiveHead() catch return;
        if (framedBody(&req)) slot.readBody() else slot.unbounded();
        const keep = handleOne(arena.allocator(), io, &req, slot, password, userdata, handler) catch return;
        if (!keep) return;
    }
}

fn framedBody(req: *const http.Server.Request) bool {
    return req.head.method.requestHasBody() and
        (req.head.content_length != null or req.head.transfer_encoding != .none);
}

fn handleOne(
    arena: Allocator,
    io: Io,
    req: *http.Server.Request,
    slot: *limits.Slot,
    password: []const u8,
    userdata: *anyopaque,
    handler: Handler,
) !bool {
    const target = try arena.dupe(u8, req.head.target);
    const q = std.mem.indexOfScalar(u8, target, '?');
    var c: Ctx = .{
        .io = io,
        .arena = arena,
        .method = req.head.method,
        .path = if (q) |i| target[0..i] else target,
        .query = if (q) |i| target[i + 1 ..] else "",
        .req = req,
        .slot = slot,
    };

    if (!auth.check(authorization(req), password)) {
        c.responded = true;
        try req.respond("{\"error\":\"unauthorized\"}", .{
            .status = .unauthorized,
            .keep_alive = c.canKeepAlive(),
            .extra_headers = &.{
                .{ .name = "www-authenticate", .value = "Basic realm=\"zeta\"" },
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return c.canKeepAlive() and req.head.keep_alive;
    }

    handler(userdata, &c) catch |err| {
        if (c.responded) return false;
        const status: http.Status = switch (err) {
            error.BodyTooLarge => .payload_too_large,
            error.SyntaxError,
            error.UnexpectedEndOfInput,
            error.UnknownField,
            error.MissingField,
            error.InvalidCharacter,
            error.UnexpectedToken,
            error.InvalidQuery,
            error.InvalidConfig,
            error.InvalidPluginConfig,
            error.InvalidProfile,
            error.RelativeLocation,
            error.InvalidCursor,
            error.InvalidLimit,
            error.InvalidCredentials,
            error.InvalidProviderId,
            error.InvalidApiKey,
            error.InvalidPatch,
            error.Overflow,
            error.InvalidEnumTag,
            error.InvalidImageMime,
            error.InvalidImageData,
            error.ModelDoesNotSupportImages,
            error.NoModel,
            => .bad_request,
            error.ConfigTooLarge, error.CredentialsTooLarge => .payload_too_large,
            error.SessionNotFound, error.MessageNotFound => .not_found,
            error.SessionBusy => .conflict,
            error.McpPkceUnsupported => .bad_gateway,
            else => .internal_server_error,
        };
        c.fail(status, @errorName(err)) catch return false;
    };
    if (!c.responded) try c.fail(.not_found, "not found");
    return c.canKeepAlive() and req.head.keep_alive;
}

fn authorization(req: *const http.Server.Request) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) return h.value;
    }
    return null;
}

pub fn segments(path: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |s| {
        if (n == out.len) return out[0..0];
        out[n] = s;
        n += 1;
    }
    return out[0..n];
}

test segments {
    var buf: [4][]const u8 = undefined;
    const s = segments("/sessions/ses_1/prompt", &buf);
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqualStrings("ses_1", s[1]);
}
