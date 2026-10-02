//! MCP server status, retry and sign-in. Response strings are request-arena
//! owned.
const std = @import("std");
const Client = @import("Client.zig");
const api = @import("session_api.zig");
const check = api.check;
const A = std.mem.Allocator;

pub const Status = struct {
    name: []const u8,
    /// `pending`, `connected`, `disabled`, `failed` or `needs_auth`.
    status: []const u8,
    tools: usize = 0,
    @"error": ?[]const u8 = null,
    /// The latest sign-in for it: `running`, `done` or `failed`.
    signIn: ?struct { id: u64, state: []const u8 } = null,
};

/// The project's MCP servers; asking starts them if nothing has yet.
pub fn list(c: *Client, a: A, location: []const u8) ![]const Status {
    const response = try c.get(a, try std.fmt.allocPrint(a, "/mcp?location={s}", .{try api.encode(a, location)}));
    try check(response);
    const body = try std.json.parseFromSliceLeaky(struct { servers: []const Status }, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return body.servers;
}

/// Connects the named server again.
pub fn connect(c: *Client, a: A, location: []const u8, name: []const u8) !void {
    try check(try c.postJson(a, try std.fmt.allocPrint(a, "/mcp/{s}/connect", .{try api.encode(a, name)}), .{ .location = location }));
}

pub const SignIn = struct { id: u64 = 0, url: []const u8, instructions: []const u8 };

/// Starts signing in to the named server: the URL to open. The server
/// connects once the sign-in is done.
pub fn auth(c: *Client, a: A, location: []const u8, name: []const u8) !SignIn {
    const response = try c.postJson(a, try std.fmt.allocPrint(a, "/mcp/{s}/auth", .{try api.encode(a, name)}), .{ .location = location });
    try check(response);
    return std.json.parseFromSliceLeaky(SignIn, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Forgets the named server's sign-in.
pub fn logout(c: *Client, a: A, location: []const u8, name: []const u8) !void {
    try check(try c.delete(a, try std.fmt.allocPrint(a, "/mcp/{s}/auth?location={s}", .{ try api.encode(a, name), try api.encode(a, location) })));
}

/// One line for a status bar, e.g. `MCP: git connected (4 tools), docs failed: timeout`.
pub fn summary(buf: []u8, servers: []const Status) []const u8 {
    if (servers.len == 0) return "MCP: no servers configured.";
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("MCP:") catch return buf[0..w.end];
    for (servers, 0..) |s, i| {
        w.print("{s} {s} {s}", .{ if (i == 0) "" else ",", s.name, s.status }) catch return buf[0..w.end];
        if (std.mem.eql(u8, s.status, "connected")) w.print(" ({d} tools)", .{s.tools}) catch return buf[0..w.end];
        if (s.@"error") |e| w.print(": {s}", .{e}) catch return buf[0..w.end];
    }
    return buf[0..w.end];
}

test summary {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("MCP: git connected (4 tools), docs failed: timeout", summary(&buf, &.{
        .{ .name = "git", .status = "connected", .tools = 4 },
        .{ .name = "docs", .status = "failed", .@"error" = "timeout" },
    }));
    var small: [12]u8 = undefined;
    try std.testing.expectEqualStrings("MCP: git con", summary(&small, &.{.{ .name = "git", .status = "connected" }}));
}
