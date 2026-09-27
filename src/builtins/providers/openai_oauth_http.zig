//! ChatGPT sign-in wire details: the authorization URL and token parsing.
//! Generic OAuth helpers live in `../oauth_http.zig`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const credentials = @import("platform").credentials;
const b64 = std.base64.url_safe_no_pad;

const shared = @import("../oauth_http.zig");
pub const Response = shared.Response;
pub const post = shared.post;
pub const expectSuccess = shared.expectSuccess;
pub const form = shared.form;
pub const queryParam = shared.queryParam;
pub const json = shared.json;
pub const string = shared.string;

pub const Authorization = struct {
    url: []const u8,
    state: []const u8,
    verifier: []const u8,
};

/// Creates the PKCE verifier/challenge and the browser authorization URL.
/// All returned slices are owned by `a`.
pub fn authorize(a: Allocator, io: Io, issuer_url: []const u8, redirect: []const u8, client_id: []const u8) !Authorization {
    const p = try shared.pkce(a, io);
    var url: Io.Writer.Allocating = .init(a);
    try url.writer.print("{s}/oauth/authorize?response_type=code", .{issuer_url});
    try form(&url.writer, "client_id", client_id);
    try form(&url.writer, "redirect_uri", redirect);
    try form(&url.writer, "scope", "openid profile email offline_access");
    try form(&url.writer, "code_challenge", p.challenge);
    try form(&url.writer, "code_challenge_method", "S256");
    try form(&url.writer, "id_token_add_organizations", "true");
    try form(&url.writer, "codex_cli_simplified_flow", "true");
    try form(&url.writer, "state", p.state);
    try form(&url.writer, "originator", "zeta");
    return .{ .url = url.written(), .state = p.state, .verifier = p.verifier };
}

pub fn tokens(a: Allocator, io: Io, value: std.json.Value) !credentials.OAuthValue {
    return tokensWithFallback(a, io, value, null);
}

pub fn tokensWithFallback(a: Allocator, io: Io, value: std.json.Value, old_refresh: ?[]const u8) !credentials.OAuthValue {
    const access_token = try string(value, "access_token");
    const id_token = if (value.object.get("id_token")) |v| if (v == .string) v.string else "" else "";
    const refresh_token = if (value.object.get("refresh_token")) |v| if (v == .string and v.string.len > 0) v.string else old_refresh orelse return error.InvalidOAuthResponse else old_refresh orelse return error.InvalidOAuthResponse;
    const expires = value.object.get("expires_in") orelse std.json.Value{ .integer = 3600 };
    const seconds: i64 = if (expires == .integer and expires.integer > 0 and expires.integer < 86400 * 365) expires.integer else 3600;
    return .{ .access = access_token, .refresh = refresh_token, .expires = Io.Clock.real.now(io).toMilliseconds() + seconds * 1000, .account_id = try accountId(a, id_token) orelse try accountId(a, access_token) };
}

fn accountId(a: Allocator, token: []const u8) !?[]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next();
    const payload = parts.next() orelse return null;
    const bytes = try a.alloc(u8, b64.Decoder.calcSizeForSlice(payload) catch return null);
    b64.Decoder.decode(bytes, payload) catch return null;
    const value = json(a, bytes) catch return null;
    if (value != .object) return null;
    if (value.object.get("chatgpt_account_id")) |v| if (v == .string) return v.string;
    if (value.object.get("https://api.openai.com/auth")) |nested| {
        if (nested == .object) if (nested.object.get("chatgpt_account_id")) |v| if (v == .string) return v.string;
    }
    if (value.object.get("organizations")) |orgs| {
        if (orgs == .array and orgs.array.items.len > 0) {
            const first = orgs.array.items[0];
            if (first == .object) if (first.object.get("id")) |v| if (v == .string) return v.string;
        }
    }
    return null;
}

test "authorization URL carries matching PKCE challenge and fresh state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try authorize(a, std.testing.io, "https://auth.openai.com", "http://localhost:1455/auth/callback", "client");
    const two = try authorize(a, std.testing.io, "https://auth.openai.com", "http://localhost:1455/auth/callback", "client");
    try std.testing.expectEqual(@as(usize, 43), one.verifier.len);
    try std.testing.expect(!std.mem.eql(u8, one.state, two.state));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(one.verifier, &hash, .{});
    var encoded: [b64.Encoder.calcSize(32)]u8 = undefined;
    const challenge = b64.Encoder.encode(&encoded, &hash);
    try std.testing.expect(std.mem.indexOf(u8, one.url, challenge) != null);
    try std.testing.expect(std.mem.indexOf(u8, one.url, "?response_type=code&client_id=") != null);
}

test "token parsing extracts account claim and accepts refresh fallback" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try json(a, "{\"access_token\":\"a.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0In0.b\",\"expires_in\":3600}");
    const parsed = try tokensWithFallback(a, std.testing.io, value, "old-refresh");
    try std.testing.expectEqualStrings("old-refresh", parsed.refresh);
    try std.testing.expectEqualStrings("acct", parsed.account_id.?);
}

test "compressed token responses are decoded before JSON parsing" {
    const Fixture = @import("openai_oauth_fixture.zig").Fixture;
    const io = std.testing.io;
    for ([_]@FieldType(Fixture, "token_encoding"){ .gzip, .deflate }) |encoding| {
        var fixture = try Fixture.init(io);
        defer fixture.listener.deinit(io);
        fixture.token_encoding = encoding;
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Fixture.serve, .{ &fixture, io });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const url = try std.fmt.allocPrint(a, "{s}/oauth/token", .{try fixture.url(a)});
        const response = try post(a, io, url, "application/x-www-form-urlencoded", "grant_type=authorization_code&code=fixture", false, 1000);
        const credential = try tokens(a, io, try json(a, response.body));
        try std.testing.expectEqualStrings("access", credential.access);
        try std.testing.expectEqualStrings("refresh", credential.refresh);
        try std.testing.expectEqualStrings("acct", credential.account_id.?);
    }
}
