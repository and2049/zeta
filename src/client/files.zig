//! Typed workspace file API. Results and nested strings belong to `arena`.
const std = @import("std");
const Client = @import("Client.zig");
const api = @import("session_api.zig");
const A = std.mem.Allocator;

pub const Entry = struct { name: []const u8, type: []const u8, size: ?u64 = null };
pub const Directory = struct { name: []const u8 };
pub fn directories(c: *Client, a: A, path: []const u8) ![]const Directory {
    const p = try std.fmt.allocPrint(a, "/directories?path={s}", .{try api.encode(a, path)});
    return (try request(struct { entries: []const Directory }, c, a, p)).entries;
}
pub const Match = struct { path: []const u8, score: usize };
pub const Read = struct { content: []const u8, size: u64, offset: usize };

fn request(comptime T: type, c: *Client, a: A, path: []const u8) !T {
    const response = try c.get(a, path);
    try api.check(response);
    return std.json.parseFromSliceLeaky(T, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn list(c: *Client, a: A, location: []const u8, path: []const u8) ![]const Entry {
    const p = try std.fmt.allocPrint(a, "/files?location={s}&path={s}", .{ try api.encode(a, location), try api.encode(a, path) });
    return (try request(struct { entries: []const Entry }, c, a, p)).entries;
}

pub fn find(c: *Client, a: A, location: []const u8, q: []const u8, limit: usize) ![]const Match {
    const p = try std.fmt.allocPrint(a, "/files/find?location={s}&q={s}&limit={d}", .{ try api.encode(a, location), try api.encode(a, q), limit });
    return (try request(struct { matches: []const Match }, c, a, p)).matches;
}

pub fn read(c: *Client, a: A, location: []const u8, path: []const u8, offset: usize, limit: usize) !Read {
    const p = try std.fmt.allocPrint(a, "/files/read?location={s}&path={s}&offset={d}&limit={d}", .{ try api.encode(a, location), try api.encode(a, path), offset, limit });
    return request(Read, c, a, p);
}
