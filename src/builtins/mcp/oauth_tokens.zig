//! OAuth client registration, authorization URL, and token exchange.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wire = @import("../oauth_http.zig");
const credentials = @import("platform").credentials.mcp;
const discovery = @import("oauth.zig");
const Endpoints = discovery.Endpoints;
const Client = discovery.Client;
const text = discovery.text;

/// Registers a public client for `redirect` (dynamic client registration).
pub fn register(a: Allocator, io: Io, endpoints: Endpoints, redirect: []const u8) !Client {
    const endpoint = endpoints.registration orelse return error.McpClientRegistrationUnavailable;
    const body = try std.json.Stringify.valueAlloc(a, .{
        .client_name = "zeta",
        .redirect_uris = &[_][]const u8{redirect},
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .token_endpoint_auth_method = "none",
    }, .{});
    const response = try wire.send(a, io, .{ .url = endpoint, .content_type = "application/json", .body = body, .timeout_ms = 30_000 });
    try wire.expectSuccess(response.status);
    const value = try wire.json(a, response.body);
    const method = if (value == .object) text(value, "token_endpoint_auth_method") else null;
    return .{
        .id = try wire.string(value, "client_id"),
        .secret = if (value == .object) text(value, "client_secret") else null,
        .secret_post = if (method) |m| std.mem.eql(u8, m, "client_secret_post") else null,
    };
}

/// The URL the user opens to sign in.
pub fn authorizationUrl(a: Allocator, endpoints: Endpoints, client: Client, redirect: []const u8, pkce: wire.Pkce) ![]const u8 {
    var url: Io.Writer.Allocating = .init(a);
    try url.writer.writeAll(endpoints.authorization);
    try url.writer.writeByte(if (std.mem.indexOfScalar(u8, endpoints.authorization, '?') == null) '?' else '&');
    try url.writer.writeAll("response_type=code");
    try wire.form(&url.writer, "client_id", client.id);
    try wire.form(&url.writer, "redirect_uri", redirect);
    try wire.form(&url.writer, "code_challenge", pkce.challenge);
    try wire.form(&url.writer, "code_challenge_method", "S256");
    try wire.form(&url.writer, "state", pkce.state);
    try wire.form(&url.writer, "resource", endpoints.resource);
    if (endpoints.scope) |scope| try wire.form(&url.writer, "scope", scope);
    return url.written();
}

/// Trades the authorization code for tokens, as the value to store.
pub fn exchange(a: Allocator, io: Io, url: []const u8, endpoints: Endpoints, client: Client, redirect: []const u8, code: []const u8, verifier: []const u8) !credentials.Value {
    var body: Io.Writer.Allocating = .init(a);
    try wire.form(&body.writer, "grant_type", "authorization_code");
    try wire.form(&body.writer, "code", code);
    try wire.form(&body.writer, "redirect_uri", redirect);
    try wire.form(&body.writer, "client_id", client.id);
    try wire.form(&body.writer, "code_verifier", verifier);
    try wire.form(&body.writer, "resource", endpoints.resource);
    return tokens(a, io, endpoints.token, &body, .{
        .url = url,
        .resource = endpoints.resource,
        .access = undefined,
        .client_id = client.id,
        .client_secret = client.secret,
        .secret_post = client.secret_post orelse endpoints.secret_post,
        .token_endpoint = endpoints.token,
    });
}

/// A new access token from the refresh token; the old refresh token stays
/// when the server issues none.
pub fn refresh(_: void, a: Allocator, io: Io, old: credentials.Value) anyerror!credentials.Value {
    var body: Io.Writer.Allocating = .init(a);
    try wire.form(&body.writer, "grant_type", "refresh_token");
    try wire.form(&body.writer, "refresh_token", old.refresh orelse return error.McpCannotRefresh);
    try wire.form(&body.writer, "client_id", old.client_id);
    try wire.form(&body.writer, "resource", old.resource);
    return tokens(a, io, old.token_endpoint, &body, old);
}

/// Posts a token request; a client secret goes as the client wants it
/// (`base.secret_post`), by default as HTTP Basic.
fn tokens(a: Allocator, io: Io, endpoint: []const u8, body: *Io.Writer.Allocating, base: credentials.Value) !credentials.Value {
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(a, .{ .name = "accept", .value = "application/json" });
    if (base.client_secret) |secret| {
        if (base.secret_post) try wire.form(&body.writer, "client_secret", secret) else try headers.append(a, .{ .name = "authorization", .value = try basic(a, base.client_id, secret) });
    }
    const response = try wire.send(a, io, .{ .url = endpoint, .content_type = "application/x-www-form-urlencoded", .body = body.written(), .headers = headers.items, .timeout_ms = 30_000 });
    try wire.expectSuccess(response.status);
    const value = try wire.json(a, response.body);
    var out = base;
    out.access = try wire.string(value, "access_token");
    if (text(value, "refresh_token")) |r| out.refresh = r;
    out.expires = if (value.object.get("expires_in")) |e| switch (e) {
        .integer => |seconds| if (seconds > 0) Io.Clock.real.now(io).toMilliseconds() +| seconds *| 1000 else 0,
        else => 0,
    } else 0;
    return out;
}

/// `Basic base64(id:secret)` with both form-encoded, as RFC 6749 §2.3.1 asks.
fn basic(a: Allocator, id: []const u8, secret: []const u8) ![]const u8 {
    var pair: Io.Writer.Allocating = .init(a);
    try (std.Uri.Component{ .raw = id }).formatEscaped(&pair.writer);
    try pair.writer.writeByte(':');
    try (std.Uri.Component{ .raw = secret }).formatEscaped(&pair.writer);
    const raw = pair.written();
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, "Basic ".len + enc.calcSize(raw.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = enc.encode(out["Basic ".len..], raw);
    return out;
}

test basic {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Basic aWQ6cyUzQTE=", try basic(arena.allocator(), "id", "s:1"));
}

test "the authorization URL carries PKCE, state and the resource" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const url = try authorizationUrl(arena.allocator(), .{ .authorization = "https://as.test/authorize", .token = "", .resource = "https://m.test/mcp", .scope = "a b" }, .{ .id = "cid" }, "http://127.0.0.1:5/callback", .{ .state = "st", .verifier = "v", .challenge = "ch" });
    try std.testing.expectEqualStrings("https://as.test/authorize?response_type=code&client_id=cid&redirect_uri=http%3A%2F%2F127.0.0.1%3A5%2Fcallback&code_challenge=ch&code_challenge_method=S256&state=st&resource=https%3A%2F%2Fm.test%2Fmcp&scope=a%20b", url);
}
