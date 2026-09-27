//! Project identity: the nearest enclosing git root, else the directory itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `dir` must be absolute. Result is allocated in `arena`.
pub fn resolve(arena: Allocator, io: Io, dir: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(dir)) return error.RelativeLocation;
    const clean = try std.fs.path.resolve(arena, &.{dir});
    var cur: ?[]const u8 = clean;
    while (cur) |d| : (cur = std.fs.path.dirname(d)) {
        const git = try std.fs.path.join(arena, &.{ d, ".git" });
        if (Io.Dir.cwd().access(io, git, .{})) |_| return d else |_| {}
    }
    return clean;
}

test resolve {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/src/deep");
    try tmp.dir.createDirPath(io, "plain");

    const deep = try std.fs.path.join(a, &.{ base, "repo/src/deep" });
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ base, "repo" }), try resolve(a, io, deep));
    const plain = try std.fs.path.join(a, &.{ base, "plain" });
    // The test tmp dir may itself sit inside a checkout, so only require an ancestor.
    try std.testing.expect(std.mem.startsWith(u8, plain, try resolve(a, io, plain)));
    try std.testing.expectError(error.RelativeLocation, resolve(a, io, "rel"));
}
