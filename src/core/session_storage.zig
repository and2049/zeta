//! Location-scoped log paths and directory discovery. Returned lists own an arena.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn validId(id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, "ses_") or id.len <= 4) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

pub fn locationDir(a: Allocator, root: []const u8, location: []const u8) ![]const u8 {
    const hash = @import("session.zig").locationHash(location);
    return std.fs.path.join(a, &.{ root, &hash });
}

pub fn logPath(a: Allocator, root: []const u8, location: []const u8, id: []const u8) ![]const u8 {
    if (!validId(id)) return error.InvalidSessionId;
    const hash = @import("session.zig").locationHash(location);
    return std.fmt.allocPrint(a, "{s}/{s}/{s}.jsonl", .{ root, &hash, id });
}

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    ids: []const []const u8,
    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Enumerates candidate logs for a location; callers must load each candidate
/// to validate its header and contents. Missing location dirs return empty.
pub fn list(gpa: Allocator, io: Io, root: []const u8, location: []const u8) !Listing {
    var result: Listing = .{ .arena = .init(gpa), .ids = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    const path = try locationDir(a, root, location);
    const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    defer dir.close(io);
    var iter = dir.iterate();
    var ids: std.ArrayList([]const u8) = .empty;
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const id = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (!validId(id)) continue;
        try ids.append(a, try a.dupe(u8, id));
    }
    result.ids = try ids.toOwnedSlice(a);
    std.mem.sort([]const u8, @constCast(result.ids), {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    return result;
}
