//! OAuth for remote MCP servers: find the authorization server from the
//! MCP server's protected-resource metadata (or its own origin, for servers
//! that publish none), register a client when none is configured, build
//! the PKCE authorization URL, and exchange or refresh tokens. Tokens are
//! bound to the MCP server with the `resource` parameter.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wire = @import("../oauth_http.zig");
const tokens = @import("oauth_tokens.zig");

pub const register = tokens.register;
pub const authorizationUrl = tokens.authorizationUrl;
pub const exchange = tokens.exchange;
pub const refresh = tokens.refresh;

pub const Challenge = struct {
    /// `resource_metadata` from the server's 401.
    metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

pub const Endpoints = struct {
    /// A client secret goes in the form body rather than a Basic header:
    /// only when the server lists `client_secret_post` and not
    /// `client_secret_basic` (which every server must support).
    secret_post: bool = false,
    authorization: []const u8,
    token: []const u8,
    registration: ?[]const u8 = null,
    /// The MCP server as tokens name it.
    resource: []const u8,
    scope: ?[]const u8 = null,
};

pub const Client = struct {
    id: []const u8,
    secret: ?[]const u8 = null,
    /// How registration said to send the secret, when it did: overrides
    /// what the server's metadata suggests.
    secret_post: ?bool = null,
};

/// Sends an `initialize` without credentials and reads the 401's
/// `WWW-Authenticate` parameters, waiting at most ten seconds. Anything
/// else yields no hints.
pub fn probe(a: Allocator, io: Io, url: []const u8, headers: []const std.http.Header) Io.Cancelable!Challenge {
    const Done = union(enum) { answered: anyerror!Challenge, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &storage);
    defer select.cancelDiscard();
    select.concurrent(.answered, probeRequest, .{ a, io, url, headers }) catch return .{};
    select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(10_000), Io.Clock.awake }) catch return .{};
    return switch (try select.await()) {
        .answered => |result| result catch |err| if (err == error.Canceled) error.Canceled else .{},
        .deadline => |result| blk: {
            try result;
            break :blk .{};
        },
    };
}

fn probeRequest(a: Allocator, io: Io, url: []const u8, headers: []const std.http.Header) !Challenge {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const extra = try std.mem.concat(a, std.http.Header, &.{ headers, &.{.{ .name = "accept", .value = "application/json, text/event-stream" }} });
    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra,
    });
    defer {
        if (req.connection) |c| c.closing = true;
        req.deinit();
    }
    const body =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"zeta","version":"0"}}}
    ;
    req.transfer_encoding = .{ .content_length = body.len };
    var w = try req.sendBodyUnflushed(&.{});
    try w.writer.writeAll(body);
    try w.end();
    try req.connection.?.flush();
    const response = try req.receiveHead(&.{});
    if (response.head.status != .unauthorized) return .{};
    var it = response.head.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) return parseChallenge(a, h.value);
    return .{};
}

/// `Bearer resource_metadata="…", scope="…"`.
pub fn parseChallenge(a: Allocator, header: []const u8) !Challenge {
    var out: Challenge = .{};
    var rest = header;
    if (std.ascii.startsWithIgnoreCase(rest, "bearer")) rest = rest["bearer".len..];
    while (rest.len > 0) {
        rest = std.mem.trimStart(u8, rest, " ,");
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse break;
        const key = std.mem.trim(u8, rest[0..eq], " ");
        rest = rest[eq + 1 ..];
        var value: []const u8 = undefined;
        if (rest.len > 0 and rest[0] == '"') {
            const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse rest.len;
            value = rest[1..end];
            rest = if (end < rest.len) rest[end + 1 ..] else "";
        } else {
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            value = std.mem.trim(u8, rest[0..end], " ");
            rest = rest[end..];
        }
        if (std.mem.eql(u8, key, "resource_metadata")) out.metadata = try a.dupe(u8, value);
        if (std.mem.eql(u8, key, "scope")) out.scope = try a.dupe(u8, value);
    }
    return out;
}

/// The server URL as a token resource: no query or fragment.
pub fn resource(url: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    return url[0..end];
}

const Parts = struct { scheme: []const u8, host: []const u8, port: u16, path: []const u8 };

/// An absolute http(s) URL's scheme, host (lowercase), effective port and
/// path without a trailing `/`.
fn parts(a: Allocator, url: []const u8) !Parts {
    const uri = std.Uri.parse(url) catch return error.McpInvalidUrl;
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!https and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.McpInvalidUrl;
    const host = uri.host orelse return error.McpInvalidUrl;
    const raw = try host.toRawMaybeAlloc(a);
    if (raw.len == 0) return error.McpInvalidUrl;
    const path = try uri.path.toRawMaybeAlloc(a);
    return .{
        .scheme = if (https) "https" else "http",
        .host = try std.ascii.allocLowerString(a, raw),
        .port = uri.port orelse if (https) 443 else 80,
        .path = std.mem.trimEnd(u8, path, "/"),
    };
}

/// Whether a token for resource `named` may go to the MCP server at
/// `server`: same scheme, host and port, and `named`'s path is the server's
/// path or a parent of it.
pub fn covers(a: Allocator, named: []const u8, server: []const u8) bool {
    const n = parts(a, named) catch return false;
    const s = parts(a, server) catch return false;
    if (!std.mem.eql(u8, n.scheme, s.scheme) or !std.mem.eql(u8, n.host, s.host) or n.port != s.port) return false;
    if (!std.mem.startsWith(u8, s.path, n.path)) return false;
    return s.path.len == n.path.len or s.path[n.path.len] == '/';
}

/// Sign-in traffic uses HTTPS, except on this machine.
fn secure(a: Allocator, url: []const u8) !void {
    const p = try parts(a, url);
    if (std.mem.eql(u8, p.scheme, "https")) return;
    for ([_][]const u8{ "127.0.0.1", "localhost", "::1", "[::1]" }) |local| if (std.mem.eql(u8, p.host, local)) return;
    return error.McpInsecureUrl;
}

fn origin(a: Allocator, url: []const u8) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.McpInvalidUrl;
    const host = uri.host orelse return error.McpInvalidUrl;
    var w: Io.Writer.Allocating = .init(a);
    try w.writer.print("{s}://", .{uri.scheme});
    try host.formatHost(&w.writer);
    if (uri.port) |port| try w.writer.print(":{d}", .{port});
    return w.written();
}

fn pathOf(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return "";
    const p = uri.path.percent_encoded;
    return if (std.mem.eql(u8, p, "/")) "" else std.mem.trimEnd(u8, p, "/");
}

fn getJson(a: Allocator, io: Io, url: []const u8) !?std.json.Value {
    const response = wire.send(a, io, .{ .method = .GET, .url = url, .headers = &.{.{ .name = "accept", .value = "application/json" }}, .timeout_ms = 10_000 }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (response.status != 200) return null;
    const value = wire.json(a, response.body) catch return null;
    return if (value == .object) value else null;
}

pub fn text(v: std.json.Value, key: []const u8) ?[]const u8 {
    const item = v.object.get(key) orelse return null;
    return if (item == .string and item.string.len > 0) item.string else null;
}

/// Finds where to sign in for the MCP server at `url`. Refuses plain HTTP
/// off this machine, a resource that does not cover the server, and an
/// authorization server that does not say it supports PKCE (S256).
pub fn discover(a: Allocator, io: Io, url: []const u8, hint: Challenge) !Endpoints {
    try secure(a, url);
    const base = try origin(a, url);
    const path = pathOf(url);
    const metadata = if (hint.metadata) |m| blk: {
        try secure(a, m);
        break :blk try getJson(a, io, m);
    } else null;
    const protected = metadata orelse (try getJson(a, io, try std.mem.concat(a, u8, &.{ base, "/.well-known/oauth-protected-resource", path }))) orelse
        if (path.len > 0) try getJson(a, io, try std.mem.concat(a, u8, &.{ base, "/.well-known/oauth-protected-resource" })) else null;
    var out: Endpoints = .{ .authorization = undefined, .token = undefined, .resource = resource(url), .scope = hint.scope };
    // Without resource metadata the MCP server's origin is the
    // authorization server (the older protocol revision).
    var issuer = base;
    if (protected) |p| {
        if (text(p, "resource")) |named| {
            // A token for a resource that does not cover this server would
            // be sent to it; refuse.
            if (!covers(a, named, url)) return error.McpResourceMismatch;
            out.resource = named;
        }
        if (p.object.get("authorization_servers")) |list| if (list == .array and list.array.items.len > 0 and list.array.items[0] == .string) {
            issuer = std.mem.trimEnd(u8, list.array.items[0].string, "/");
        };
        if (out.scope == null) if (p.object.get("scopes_supported")) |scopes| if (scopes == .array) {
            var joined: std.ArrayList(u8) = .empty;
            for (scopes.array.items) |scope| if (scope == .string) {
                if (joined.items.len > 0) try joined.append(a, ' ');
                try joined.appendSlice(a, scope.string);
            };
            if (joined.items.len > 0) out.scope = joined.items;
        };
    }
    try secure(a, issuer);
    const issuer_base = try origin(a, issuer);
    const issuer_path = pathOf(issuer);
    const candidates = if (issuer_path.len > 0) [_][]const u8{
        try std.mem.concat(a, u8, &.{ issuer_base, "/.well-known/oauth-authorization-server", issuer_path }),
        try std.mem.concat(a, u8, &.{ issuer_base, "/.well-known/openid-configuration", issuer_path }),
        try std.mem.concat(a, u8, &.{ issuer, "/.well-known/openid-configuration" }),
    } else [_][]const u8{
        try std.mem.concat(a, u8, &.{ issuer_base, "/.well-known/oauth-authorization-server" }),
        try std.mem.concat(a, u8, &.{ issuer_base, "/.well-known/openid-configuration" }),
        "",
    };
    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        const found = (try getJson(a, io, candidate)) orelse continue;
        // Metadata naming another issuer must not be used (RFC 8414 §3.3).
        const named = std.mem.trimEnd(u8, text(found, "issuer") orelse "", "/");
        if (!std.mem.eql(u8, named, issuer)) return error.McpIssuerMismatch;
        out.authorization = text(found, "authorization_endpoint") orelse continue;
        out.token = text(found, "token_endpoint") orelse continue;
        out.registration = text(found, "registration_endpoint");
        if (!supportsPkce(found)) return error.McpPkceUnsupported;
        out.secret_post = lists(found, "token_endpoint_auth_methods_supported", "client_secret_post") and
            !lists(found, "token_endpoint_auth_methods_supported", "client_secret_basic");
        try secure(a, out.authorization);
        try secure(a, out.token);
        if (out.registration) |r| try secure(a, r);
        return out;
    }
    // Without metadata there is no word that PKCE is supported.
    return error.McpAuthorizationServerUnknown;
}

fn supportsPkce(metadata: std.json.Value) bool {
    return lists(metadata, "code_challenge_methods_supported", "S256");
}

fn lists(metadata: std.json.Value, key: []const u8, wanted: []const u8) bool {
    const list = metadata.object.get(key) orelse return false;
    if (list != .array) return false;
    for (list.array.items) |m| if (m == .string and std.mem.eql(u8, m.string, wanted)) return true;
    return false;
}

test "a resource covers its own server and servers below it, nothing else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(covers(a, "https://m.test/mcp", "https://M.test:443/mcp/"));
    try std.testing.expect(covers(a, "https://m.test", "https://m.test/mcp"));
    try std.testing.expect(!covers(a, "https://m.test", "https://m.test.evil.test/mcp"));
    try std.testing.expect(!covers(a, "https://m.test/mc", "https://m.test/mcp"));
    try std.testing.expect(!covers(a, "https://m.test/mcp", "http://m.test/mcp"));
    try std.testing.expect(!covers(a, "https:issuer", "https://m.test/mcp"));
    try std.testing.expectError(error.McpInsecureUrl, secure(a, "http://as.test/token"));
    try secure(a, "http://127.0.0.1:8080/token");
    try std.testing.expectError(error.McpInvalidUrl, origin(a, "https:issuer"));
}

test parseChallenge {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try parseChallenge(arena.allocator(), "Bearer error=\"invalid_token\", resource_metadata=\"https://m.test/.well-known/oauth-protected-resource\", scope=\"files:read files:write\"");
    try std.testing.expectEqualStrings("https://m.test/.well-known/oauth-protected-resource", c.metadata.?);
    try std.testing.expectEqualStrings("files:read files:write", c.scope.?);
    try std.testing.expectEqualStrings("https://m.test/mcp", resource("https://m.test/mcp?x=1#f"));
}

test {
    _ = tokens;
}
