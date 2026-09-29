//! Access tokens for one remote MCP server from its stored sign-in
//! (`mcp:<server>` in the credential store, bound to the server's URL).
//! The token is cached for the connection and refreshed when it expires
//! within a minute or the server refuses it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const credentials = @import("platform").credentials.mcp;
const oauth = @import("oauth.zig");

pub const Bearer = struct {
    gpa: Allocator,
    io: Io,
    data_dir: []const u8,
    /// `mcp:<server>`; owned.
    key: []u8,
    url: []u8,
    mutex: Io.Mutex = .init,
    token: ?credentials.Token = null,

    /// Copies what it keeps.
    pub fn init(gpa: Allocator, io: Io, data_dir: []const u8, server: []const u8, url: []const u8) !Bearer {
        var buf: [256]u8 = undefined;
        const key = try gpa.dupe(u8, try credentials.id(&buf, server));
        errdefer gpa.free(key);
        return .{ .gpa = gpa, .io = io, .data_dir = data_dir, .key = key, .url = try gpa.dupe(u8, url) };
    }

    pub fn deinit(b: *Bearer) void {
        if (b.token) |*t| t.deinit();
        b.gpa.free(b.key);
        b.gpa.free(b.url);
    }

    /// `Bearer <token>` in `a`, or null when the server has no sign-in.
    pub fn header(b: *Bearer, a: Allocator) !?[]const u8 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const now = Io.Clock.real.now(b.io).toMilliseconds();
        const usable = if (b.token) |t| t.value.expires == 0 or t.value.expires > now +| 60_000 else false;
        if (!usable) try b.reload(null);
        const t = b.token orelse return null;
        return try std.fmt.allocPrint(a, "Bearer {s}", .{t.value.access});
    }

    /// The token already held, never refreshed: for requests on the way out,
    /// which must not spend a rotating refresh token.
    pub fn cached(b: *Bearer, a: Allocator) !?[]const u8 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const t = b.token orelse return null;
        return try std.fmt.allocPrint(a, "Bearer {s}", .{t.value.access});
    }

    /// The server refused `sent` (a header from `header`): refreshes the
    /// sign-in. True when a different token is now available.
    pub fn refused(b: *Bearer, sent: []const u8) !bool {
        const access = if (std.mem.startsWith(u8, sent, "Bearer ")) sent["Bearer ".len..] else sent;
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        try b.reload(access);
        const t = b.token orelse return false;
        return !std.mem.eql(u8, t.value.access, access);
    }

    /// Caller holds `mutex`.
    fn reload(b: *Bearer, stale: ?[]const u8) !void {
        const next = try credentials.fresh(b.gpa, b.io, b.data_dir, b.key, b.url, stale, {}, oauth.refresh);
        if (b.token) |*t| t.deinit();
        b.token = next;
    }
};

test "a stored sign-in becomes the header; a refused one without a refresh token has no successor" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var b: Bearer = try .init(gpa, io, dir, "docs", "https://m.test/mcp");
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expect(try b.header(arena.allocator()) == null);
    try credentials.put(gpa, io, dir, "mcp:docs", .{ .url = "https://m.test/mcp", .resource = "https://m.test/mcp", .access = "tok", .client_id = "c", .token_endpoint = "http://127.0.0.1:1/token" });
    try std.testing.expectEqualStrings("Bearer tok", (try b.header(arena.allocator())).?);
    // No refresh token: there is nothing better to send.
    try std.testing.expect(!try b.refused("Bearer tok"));
}
