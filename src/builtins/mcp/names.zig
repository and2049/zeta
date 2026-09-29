//! Tool names for MCP tools: `mcp__<server>__<tool>`, with characters
//! outside `[A-Za-z0-9_-]` replaced by `_`, at most 64 bytes, and `_2`,
//! `_3`… when two tools of one server end up with the same name.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_len = 64;

pub const Taken = struct {
    used: std.StringHashMapUnmanaged(void) = .empty,

    /// A name not yet handed out by this set, in `arena`.
    pub fn claim(t: *Taken, arena: Allocator, server: []const u8, tool: []const u8) ![]const u8 {
        const base = try sanitize(arena, try std.fmt.allocPrint(arena, "mcp__{s}__{s}", .{ server, tool }));
        var candidate = base;
        var n: usize = 2;
        while (t.used.contains(candidate)) : (n += 1) {
            var suffix_buf: [24]u8 = undefined;
            const suffix = try std.fmt.bufPrint(&suffix_buf, "_{d}", .{n});
            candidate = try std.mem.concat(arena, u8, &.{ base[0..@min(base.len, max_len - suffix.len)], suffix });
        }
        try t.used.put(arena, candidate, {});
        return candidate;
    }
};

/// What every tool name of `server` starts with, in `arena`.
pub fn prefix(arena: Allocator, server: []const u8) ![]const u8 {
    return sanitize(arena, try std.fmt.allocPrint(arena, "mcp__{s}__", .{server}));
}

fn sanitize(arena: Allocator, name: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, name[0..@min(name.len, max_len)]);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_' and c.* != '-') c.* = '_';
    }
    return out;
}

test "names are sanitized, capped and made unique" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var taken: Taken = .{};
    try std.testing.expectEqualStrings("mcp__git__status", try taken.claim(a, "git", "status"));
    try std.testing.expectEqualStrings("mcp__my_srv__read_file", try taken.claim(a, "my.srv", "read file"));
    try std.testing.expectEqualStrings("mcp__my_srv__read_file_2", try taken.claim(a, "my.srv", "read.file"));
    try std.testing.expectEqualStrings("mcp__my_srv__", try prefix(a, "my.srv"));
    const long = try taken.claim(a, "server", "a" ** 80);
    try std.testing.expectEqual(@as(usize, max_len), long.len);
    const again = try taken.claim(a, "server", "a" ** 81);
    try std.testing.expectEqual(@as(usize, max_len), again.len);
    try std.testing.expect(std.mem.endsWith(u8, again, "_2"));
}
