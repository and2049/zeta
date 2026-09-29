//! `oauth.discover` against a local metadata server.
const std = @import("std");
const Io = std.Io;
const oauth = @import("oauth.zig");

/// Serves fixed JSON bodies by path (404 otherwise) and records the paths
/// asked for, in order.
const Fixture = struct {
    server: Io.net.Server,
    port: u16,
    routes: []const Route = &.{},
    asked: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    const Route = struct { path: []const u8, body: []const u8 };

    fn init(gpa: std.mem.Allocator, io: Io) !Fixture {
        const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        const server = try addr.listen(io, .{});
        return .{ .server = server, .port = server.socket.address.getPort(), .arena = .init(gpa) };
    }

    fn deinit(f: *Fixture, io: Io) void {
        f.server.deinit(io);
        f.arena.deinit();
    }

    fn url(f: *Fixture, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.arena.allocator(), "http://127.0.0.1:{d}{s}", .{ f.port, path });
    }

    fn serve(f: *Fixture, io: Io) Io.Cancelable!void {
        while (true) {
            const stream = f.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            defer stream.close(io);
            var in: [4096]u8 = undefined;
            var reader = stream.reader(io, &in);
            var out: [4096]u8 = undefined;
            var writer = stream.writer(io, &out);
            var http: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = http.receiveHead() catch continue;
            const path = f.arena.allocator().dupe(u8, request.head.target) catch continue;
            f.asked.append(f.arena.allocator(), path) catch continue;
            const body = for (f.routes) |r| {
                if (std.mem.eql(u8, r.path, path)) break r.body;
            } else null;
            request.respond(body orelse "", .{ .status = if (body == null) .not_found else .ok, .keep_alive = false }) catch continue;
        }
    }
};

fn authServer(a: std.mem.Allocator, issuer: []const u8, base: []const u8, pkce: bool) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"issuer":"{s}","authorization_endpoint":"{s}/authorize","token_endpoint":"{s}/token","code_challenge_methods_supported":[{s}]}}
    , .{ issuer, base, base, if (pkce) "\"S256\"" else "" });
}

fn protectedResource(a: std.mem.Allocator, resource: []const u8, issuer: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"resource":"{s}","authorization_servers":["{s}"],"scopes_supported":["read"]}}
    , .{ resource, issuer });
}

/// Runs `discover` for `<fixture>/mcp` with `routes` served.
fn discover(f: *Fixture, io: Io, routes: []const Fixture.Route) !oauth.Endpoints {
    f.routes = routes;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ f, io });
    return oauth.discover(f.arena.allocator(), io, try f.url("/mcp"), .{});
}

test "an issuer with a path is looked up path-inserted first, then as OpenID" {
    const io = std.testing.io;
    var f: Fixture = try .init(std.testing.allocator, io);
    defer f.deinit(io);
    const a = f.arena.allocator();
    const issuer = try f.url("/tenant");
    const got = try discover(&f, io, &.{
        .{ .path = "/.well-known/oauth-protected-resource/mcp", .body = try protectedResource(a, try f.url("/mcp"), issuer) },
        .{ .path = "/.well-known/openid-configuration/tenant", .body = try authServer(a, issuer, issuer, true) },
    });
    try std.testing.expectEqualStrings(try f.url("/tenant/token"), got.token);
    try std.testing.expectEqualStrings("read", got.scope.?);
    const want = [_][]const u8{
        "/.well-known/oauth-protected-resource/mcp",
        "/.well-known/oauth-authorization-server/tenant",
        "/.well-known/openid-configuration/tenant",
    };
    try std.testing.expectEqual(want.len, f.asked.items.len);
    for (want, f.asked.items) |w, got_path| try std.testing.expectEqualStrings(w, got_path);
}

test "without resource metadata the server's origin is the authorization server" {
    const io = std.testing.io;
    var f: Fixture = try .init(std.testing.allocator, io);
    defer f.deinit(io);
    const origin = try f.url("");
    const got = try discover(&f, io, &.{
        .{ .path = "/.well-known/oauth-authorization-server", .body = try authServer(f.arena.allocator(), try f.url("/"), origin, true) },
    });
    try std.testing.expectEqualStrings(try f.url("/authorize"), got.authorization);
    try std.testing.expectEqualStrings(try f.url("/mcp"), got.resource);
}

test "metadata for another issuer, another resource, or without PKCE is refused" {
    const io = std.testing.io;
    const cases = [_]struct { resource: []const u8, named_issuer: []const u8, pkce: bool, want: anyerror }{
        .{ .resource = "/mcp", .named_issuer = "/other", .pkce = true, .want = error.McpIssuerMismatch },
        .{ .resource = "/elsewhere", .named_issuer = "/as", .pkce = true, .want = error.McpResourceMismatch },
        .{ .resource = "/mcp", .named_issuer = "/as", .pkce = false, .want = error.McpPkceUnsupported },
    };
    for (cases) |case| {
        var f: Fixture = try .init(std.testing.allocator, io);
        defer f.deinit(io);
        const a = f.arena.allocator();
        const issuer = try f.url("/as");
        try std.testing.expectError(case.want, discover(&f, io, &.{
            .{ .path = "/.well-known/oauth-protected-resource/mcp", .body = try protectedResource(a, try f.url(case.resource), issuer) },
            .{ .path = "/.well-known/oauth-authorization-server/as", .body = try authServer(a, try f.url(case.named_issuer), issuer, case.pkce) },
        }));
    }
}

test "an authorization server off this machine must use HTTPS" {
    const io = std.testing.io;
    var f: Fixture = try .init(std.testing.allocator, io);
    defer f.deinit(io);
    try std.testing.expectError(error.McpInsecureUrl, discover(&f, io, &.{
        .{ .path = "/.well-known/oauth-protected-resource/mcp", .body = try protectedResource(f.arena.allocator(), try f.url("/mcp"), "http://auth.example") },
    }));
}
