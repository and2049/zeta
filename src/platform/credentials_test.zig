const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const credentials = @import("credentials.zig");

test "OAuth round trip, API-key compatibility and private metadata" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data = buf[0..try tmp.dir.realPath(io, &buf)];
    try credentials.putApiKey(a, io, data, "other", "api-secret");
    try credentials.putOAuth(a, io, data, "openai", .{ .access = "access-secret", .refresh = "refresh-secret", .expires = std.math.maxInt(i64), .account_id = "account-secret" });
    try std.testing.expect((try credentials.readKey(a, io, data, "openai")) == null);
    var value = (try credentials.readOAuth(a, io, data, "openai")).?;
    defer value.deinit();
    try std.testing.expectEqualStrings("access-secret", value.access);
    try std.testing.expectEqualStrings("refresh-secret", value.refresh);
    try std.testing.expectEqualStrings("account-secret", value.account_id.?);
    var listing = try credentials.list(a, io, data);
    defer listing.deinit();
    for (listing.items) |item| {
        try std.testing.expect(std.mem.indexOf(u8, item.id, "secret") == null);
        try std.testing.expect(std.mem.eql(u8, item.type, "oauth") or std.mem.eql(u8, item.type, "api"));
    }
    var fresh = (try credentials.getFreshOAuth(a, io, data, "openai", {}, struct {
        fn refresh(_: void, _: Allocator, _: Io, _: credentials.OAuthValue) !credentials.OAuthValue {
            return error.UnexpectedRefresh;
        }
    }.refresh)).?;
    defer fresh.deinit();
    try std.testing.expectEqualStrings(value.access, fresh.access);
}

test "OAuth refresh saves rotated token and retains account ID" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data = buf[0..try tmp.dir.realPath(io, &buf)];
    try credentials.putOAuth(a, io, data, "openai", .{ .access = "old", .refresh = "old-refresh", .expires = 0, .account_id = "acct" });
    const replacement = struct {
        fn run(_: void, _: Allocator, _: Io, old: credentials.OAuthValue) !credentials.OAuthValue {
            try std.testing.expectEqualStrings("old-refresh", old.refresh);
            return .{ .access = "new", .refresh = "new-refresh", .expires = std.math.maxInt(i64) };
        }
    }.run;
    var first = (try credentials.getFreshOAuth(a, io, data, "openai", {}, replacement)).?;
    defer first.deinit();
    try std.testing.expectEqualStrings("acct", first.account_id.?);
    var second = (try credentials.getFreshOAuth(a, io, data, "openai", {}, replacement)).?;
    defer second.deinit();
    try std.testing.expectEqualStrings("new-refresh", second.refresh);
}
