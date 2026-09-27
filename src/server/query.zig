//! Small strict query decoder. Returned strings are request-arena owned.
const std = @import("std");

pub fn get(arena: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try decode(arena, pair[0..equals]);
        if (!std.mem.eql(u8, key, name)) continue;
        if (result != null) return error.InvalidQuery;
        result = try decode(arena, if (equals < pair.len) pair[equals + 1 ..] else "");
    }
    return result;
}

fn decode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte = switch (text[i]) {
            '+' => ' ',
            '%' => blk: {
                if (i + 2 >= text.len) return error.InvalidQuery;
                const b = std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16) catch return error.InvalidQuery;
                i += 2;
                break :blk b;
            },
            else => text[i],
        };
        if (byte == 0) return error.InvalidQuery;
        try output.append(arena, byte);
    }
    return output.toOwnedSlice(arena);
}

test "query decoding rejects ambiguous and malformed selectors" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try std.testing.expectEqualStrings("/a b", (try get(a, "location=%2Fa+b", "location")).?);
    try std.testing.expectError(error.InvalidQuery, get(a, "location=a&location=b", "location"));
    try std.testing.expectError(error.InvalidQuery, get(a, "location=%00", "location"));
    try std.testing.expectError(error.InvalidQuery, get(a, "location=%2", "location"));
}
