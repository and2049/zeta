//! Bounded OAuth HTTP requests and wire-format helpers shared by sign-in
//! flows: PKCE, form encoding, and small JSON responses.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const b64 = std.base64.url_safe_no_pad;
const max_response = 64 * 1024;

pub const Response = struct { status: u16, body: []const u8 };

pub const Pkce = struct {
    state: []const u8,
    verifier: []const u8,
    challenge: []const u8,
};

/// A fresh `state` and S256 verifier/challenge, owned by `a`.
pub fn pkce(a: Allocator, io: Io) !Pkce {
    var nonce: [32]u8 = undefined;
    try Io.randomSecure(io, &nonce);
    const state = b64.Encoder.encode(try a.alloc(u8, b64.Encoder.calcSize(nonce.len)), &nonce);
    var random: [43]u8 = undefined;
    try Io.randomSecure(io, &random);
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    const verifier = try a.alloc(u8, random.len);
    for (random, 0..) |byte, i| verifier[i] = alphabet[byte % alphabet.len];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = b64.Encoder.encode(try a.alloc(u8, b64.Encoder.calcSize(digest.len)), &digest);
    return .{ .state = state, .verifier = verifier, .challenge = challenge };
}

pub const Request = struct {
    method: std.http.Method = .POST,
    url: []const u8,
    content_type: ?[]const u8 = null,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// A 403 or 404 still returns its body (device-code polling).
    allow_pending: bool = false,
    timeout_ms: i64 = 30_000,
};

/// Sends one request with a deadline. Other non-2xx answers return their
/// status with an empty body: bodies of failed sign-in requests are never
/// passed on.
pub fn send(a: Allocator, io: Io, r: Request) !Response {
    const Result = union(enum) { request: anyerror!Response, deadline: Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var select: Io.Select(Result) = .init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.request, exchange, .{ a, io, r });
    try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(r.timeout_ms), Io.Clock.awake });
    return switch (try select.await()) {
        .request => |result| try result,
        .deadline => |result| blk: {
            try result;
            break :blk error.OAuthHttpTimeout;
        },
    };
}

pub fn post(a: Allocator, io: Io, url: []const u8, content_type: []const u8, body: []const u8, allow_pending: bool, timeout_ms: i64) !Response {
    return send(a, io, .{ .url = url, .content_type = content_type, .body = body, .allow_pending = allow_pending, .timeout_ms = timeout_ms });
}

fn exchange(a: Allocator, io: Io, r: Request) !Response {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var req = try client.request(r.method, try std.Uri.parse(r.url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = if (r.content_type) |t| .{ .override = t } else .default },
        .extra_headers = r.headers,
    });
    defer {
        if (req.connection) |connection| connection.closing = true;
        req.deinit();
    }
    if (r.body) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(body);
        try writer.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    const status: u16 = @intFromEnum(response.head.status);
    if ((status < 200 or status >= 300) and !(r.allow_pending and (status == 403 or status == 404))) return .{ .status = status, .body = "" };
    var transfer: [8192]u8 = undefined;
    // Client advertises gzip/deflate by default. Bound the decoded JSON, not
    // just the compressed payload (real token responses can be compressed).
    var decompress: std.http.Decompress = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    const content = try response.readerDecompressing(&transfer, &decompress, &window).allocRemaining(a, .limited(max_response));
    return .{ .status = status, .body = content };
}

/// Report status classes without returning provider bodies containing secrets.
pub fn expectSuccess(status: u16) !void {
    if (status >= 200 and status < 300) return;
    return switch (status) {
        400 => error.OAuthHttpBadRequest,
        401 => error.OAuthHttpUnauthorized,
        403 => error.OAuthHttpForbidden,
        429 => error.OAuthHttpRateLimited,
        500...599 => error.OAuthHttpServerError,
        else => error.OAuthHttpUnexpectedStatus,
    };
}

pub fn form(writer: *Io.Writer, key: []const u8, value: []const u8) !void {
    if (writer.end > 0) try writer.writeByte('&');
    try writer.writeAll(key);
    try writer.writeByte('=');
    try (std.Uri.Component{ .raw = value }).formatEscaped(writer);
}

pub fn queryParam(a: Allocator, query: []const u8, key: []const u8) !?[]const u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!std.mem.eql(u8, part[0..eq], key)) continue;
        const copy = try a.dupe(u8, part[eq + 1 ..]);
        defer a.free(copy);
        return try a.dupe(u8, std.Uri.percentDecodeInPlace(copy));
    }
    return null;
}

pub fn json(a: Allocator, bytes: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch error.InvalidOAuthResponse;
}

pub fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidOAuthResponse;
    const item = value.object.get(key) orelse return error.InvalidOAuthResponse;
    if (item != .string or item.string.len == 0) return error.InvalidOAuthResponse;
    return item.string;
}

test "query and form escaping" {
    const a = std.testing.allocator;
    var writer: Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    try form(&writer.writer, "redirect_uri", "http://localhost:1455/auth/callback");
    try form(&writer.writer, "scope", "openid profile");
    try std.testing.expectEqualStrings("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid%20profile", writer.written());
    const decoded = (try queryParam(a, "state=good%2Fstate&code=ok", "state")).?;
    defer a.free(decoded);
    try std.testing.expectEqualStrings("good/state", decoded);
}

test pkce {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const one = try pkce(arena.allocator(), std.testing.io);
    const two = try pkce(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 43), one.verifier.len);
    try std.testing.expect(!std.mem.eql(u8, one.state, two.state));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(one.verifier, &hash, .{});
    var encoded: [b64.Encoder.calcSize(32)]u8 = undefined;
    try std.testing.expectEqualStrings(b64.Encoder.encode(&encoded, &hash), one.challenge);
}
