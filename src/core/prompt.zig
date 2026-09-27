const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Section = struct {
    name: []const u8,
    text: []const u8,
};

pub const base =
    \\You are zeta, a coding agent working in the user's project.
    \\Be concise and direct. Prefer small, correct changes, and say what you did.
;

pub fn environment(arena: Allocator, location: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "Project directory: {s}", .{location});
}

pub fn build(arena: Allocator, sections: []const Section) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (sections, 0..) |s, i| {
        if (i > 0) try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, s.text);
    }
    return out.items;
}

test build {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), &.{ .{ .name = "a", .text = "one" }, .{ .name = "b", .text = "two" } });
    try std.testing.expectEqualStrings("one\n\ntwo", p);
}
