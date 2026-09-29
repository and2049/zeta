//! Extension status and restart. Response strings are request-arena owned.
const std = @import("std");
const Client = @import("Client.zig");
const api = @import("session_api.zig");
const A = std.mem.Allocator;

pub const Status = struct {
    name: []const u8,
    /// `user` or `project`.
    scope: []const u8,
    /// `starting`, `running` or `failed`.
    status: []const u8,
    source: []const u8 = "",
    @"error": ?[]const u8 = null,
};

/// The extensions that apply to the project; asking starts them if nothing
/// has yet.
pub fn list(c: *Client, a: A, location: []const u8) ![]const Status {
    const response = try c.get(a, try std.fmt.allocPrint(a, "/extensions?location={s}", .{try api.encode(a, location)}));
    try api.check(response);
    const body = try std.json.parseFromSliceLeaky(struct { extensions: []const Status }, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return body.extensions;
}

pub fn restart(c: *Client, a: A, location: []const u8, name: []const u8) !void {
    try api.check(try c.postJson(a, try std.fmt.allocPrint(a, "/extensions/{s}/restart", .{try api.encode(a, name)}), .{ .location = location }));
}

/// One status-bar line, e.g. `Extensions: hello running, lint failed: exited`.
pub fn summary(buf: []u8, extensions: []const Status) []const u8 {
    if (extensions.len == 0) return "Extensions: none found.";
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("Extensions:") catch return buf[0..w.end];
    for (extensions, 0..) |e, i| {
        w.print("{s} {s} {s}", .{ if (i == 0) "" else ",", e.name, e.status }) catch return buf[0..w.end];
        if (e.@"error") |err| w.print(": {s}", .{err}) catch return buf[0..w.end];
    }
    return buf[0..w.end];
}

test summary {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Extensions: hello running, lint failed: exited", summary(&buf, &.{
        .{ .name = "hello", .scope = "project", .status = "running" },
        .{ .name = "lint", .scope = "user", .status = "failed", .@"error" = "exited" },
    }));
}
