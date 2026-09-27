//! Authentication endpoints. Response strings are request-arena owned; never log keys.
const std = @import("std");
const Client = @import("Client.zig");
const check = @import("session_api.zig").check;
const encoded = @import("session_api.zig").encode;
const A = std.mem.Allocator;

pub const Method = struct { id: []const u8, label: []const u8, type: enum { api, oauth } };
pub const Provider = struct { id: []const u8, name: []const u8, methods: []const Method };
pub const Providers = struct { providers: []const Provider };
pub const Flow = struct { id: []const u8, url: []const u8, instructions: []const u8 };
pub const Status = struct { status: enum { pending, complete, @"error" }, @"error": ?[]const u8 = null };

fn decode(comptime T: type, a: A, response: Client.Response) !T {
    try check(response);
    return std.json.parseFromSliceLeaky(T, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}
pub fn providers(c: *Client, a: A, location: []const u8) !Providers {
    return decode(Providers, a, try c.get(a, try std.fmt.allocPrint(a, "/auth/providers?location={s}", .{try encoded(a, location)})));
}
pub fn apiKey(c: *Client, a: A, provider: []const u8, key: []const u8) !void {
    try check(try c.putJson(a, try std.fmt.allocPrint(a, "/credentials/{s}", .{try encoded(a, provider)}), .{ .key = key }));
}
/// Starts `provider`'s sign-in `method`; `location` lets that project's
/// provider plugins answer.
pub fn start(c: *Client, a: A, provider: []const u8, method: []const u8, location: ?[]const u8) !Flow {
    return decode(Flow, a, try c.postJson(a, try std.fmt.allocPrint(a, "/auth/{s}/start", .{try encoded(a, provider)}), .{ .method = method, .location = location }));
}
pub fn status(c: *Client, a: A, provider: []const u8, id: []const u8) !Status {
    return decode(Status, a, try c.get(a, try std.fmt.allocPrint(a, "/auth/{s}/status?id={s}", .{ try encoded(a, provider), try encoded(a, id) })));
}
pub fn cancel(c: *Client, a: A, provider: []const u8, id: []const u8) !void {
    try check(try c.delete(a, try std.fmt.allocPrint(a, "/auth/{s}/flow?id={s}", .{ try encoded(a, provider), try encoded(a, id) })));
}

test "query components are escaped" {
    const a = std.testing.allocator;
    const value = try encoded(a, "/a b?x=y");
    defer a.free(value);
    try std.testing.expectEqualStrings("%2Fa%20b%3Fx%3Dy", value);
}
