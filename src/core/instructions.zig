//! Loads ambient AGENTS.md guidance: global first, then ancestors from the
//! filesystem root down to the selected location. No CLAUDE.md fallback.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Entry = struct {
    path: []const u8,
    text: []const u8,
};

/// Entries, paths and contents live in `arena`. The caller owns that arena.
/// `location` should be an absolute directory path.
pub fn collect(arena: Allocator, io: Io, config_dir: []const u8, location: []const u8) ![]const Entry {
    if (!std.fs.path.isAbsolute(location)) return error.InvalidLocation;
    var result: std.ArrayList(Entry) = .empty;
    try appendIfExists(arena, io, &result, try std.fs.path.join(arena, &.{ config_dir, "AGENTS.md" }));

    var ancestors: std.ArrayList([]const u8) = .empty;
    var current = std.mem.trimEnd(u8, location, "/");
    if (current.len == 0) current = "/";
    while (true) {
        try ancestors.append(arena, current);
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    var i = ancestors.items.len;
    while (i > 0) {
        i -= 1;
        try appendIfExists(arena, io, &result, try std.fs.path.join(arena, &.{ ancestors.items[i], "AGENTS.md" }));
    }
    return result.items;
}

fn appendIfExists(arena: Allocator, io: Io, out: *std.ArrayList(Entry), path: []const u8) !void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    try out.append(arena, .{ .path = path, .text = text });
}

test "global followed by ancestors, root to location" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "config");
    try tmp.dir.createDirPath(io, "project/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "config/AGENTS.md", .data = "global" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/AGENTS.md", .data = "project" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/sub/AGENTS.md", .data = "sub" });
    const cfg = try std.fs.path.join(arena, &.{ base, "config" });
    const loc = try std.fs.path.join(arena, &.{ base, "project", "sub" });
    const entries = try collect(arena, io, cfg, loc);
    // Other AGENTS.md files outside this temporary directory may exist.
    try std.testing.expect(entries.len >= 3);
    try std.testing.expectEqualStrings("global", entries[0].text);
    try std.testing.expectEqualStrings("project", entries[entries.len - 2].text);
    try std.testing.expectEqualStrings("sub", entries[entries.len - 1].text);
    try std.testing.expectError(error.InvalidLocation, collect(arena, io, cfg, "relative"));
}
