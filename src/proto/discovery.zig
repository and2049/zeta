//! The discovery file a running server publishes so clients can find it:
//! `<runtime dir>/server.json`, mode 0600.

const std = @import("std");

pub const file_name = "server.json";
pub const auth_user = "zeta";

pub const Discovery = struct {
    url: []const u8,
    pid: i64,
    version: []const u8,
    /// HTTP Basic password for user `zeta`.
    password: []const u8,

    /// Caller frees the encoded bytes with `gpa`.
    pub fn encode(d: Discovery, gpa: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(gpa, d, .{});
    }

    /// Strings in the result are allocated in `arena`.
    pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !Discovery {
        return std.json.parseFromSliceLeaky(Discovery, arena, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

/// `Basic base64(zeta:password)`, the `Authorization` header clients send.
pub fn authHeader(buf: []u8, password: []const u8) error{NoSpaceLeft}![]const u8 {
    var creds: [256]u8 = undefined;
    const plain = try std.fmt.bufPrint(&creds, "{s}:{s}", .{ auth_user, password });
    const prefix = "Basic ";
    const len = std.base64.standard.Encoder.calcSize(plain.len);
    if (buf.len < prefix.len + len) return error.NoSpaceLeft;
    @memcpy(buf[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(buf[prefix.len..][0..len], plain);
    return buf[0 .. prefix.len + len];
}

test "authHeader" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Basic emV0YTpwdw==", try authHeader(&buf, "pw"));
}

test "encode and decode round trip" {
    const d: Discovery = .{ .url = "http://127.0.0.1:4096", .pid = 42, .version = "0.0.0", .password = "pw" };
    const bytes = try d.encode(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        \\{"url":"http://127.0.0.1:4096","pid":42,"version":"0.0.0","password":"pw"}
    , bytes);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const back = try Discovery.decode(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(i64, 42), back.pid);
    try std.testing.expectEqualStrings("pw", back.password);
}
