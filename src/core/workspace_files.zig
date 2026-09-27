//! Bounded workspace browsing and completion. Returned slices belong to the caller's allocator.
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;

pub const Entry = struct { name: []const u8, type: []const u8, size: ?u64 = null };
pub const Match = struct { path: []const u8, score: usize };
pub const Read = struct { content: []const u8, size: u64, offset: usize };

/// Resolve an existing path, following links only when the final target remains inside root.
pub fn confined(a: A, io: Io, root: []const u8, relative: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative) or std.mem.indexOfScalar(u8, relative, '\\') != null) return error.InvalidPath;
    var pieces = std.mem.splitScalar(u8, relative, '/');
    while (pieces.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, root, a);
    const joined = try std.fs.path.join(a, &.{ base, relative });
    const real = try Io.Dir.realPathFileAbsoluteAlloc(io, joined, a);
    if (!std.mem.eql(u8, real, base) and !(std.mem.startsWith(u8, real, base) and
        (base.len == 1 or (real.len > base.len and real[base.len] == '/')))) return error.OutsideLocation;
    return real;
}

pub fn list(a: A, io: Io, root: []const u8, path: []const u8) ![]Entry {
    const real = try confined(a, io, root, path);
    const dir = try Io.Dir.openDirAbsolute(io, real, .{ .iterate = true });
    defer dir.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (entries.items.len >= 10000) break;
        const kind: []const u8 = switch (e.kind) {
            .directory => "dir",
            .file => "file",
            .sym_link => "symlink",
            else => continue,
        };
        const size: ?u64 = if (e.kind == .file) blk: {
            const st = dir.statFile(io, e.name, .{}) catch break :blk null;
            break :blk st.size;
        } else null;
        try entries.append(a, .{ .name = try a.dupe(u8, e.name), .type = kind, .size = size });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            if (std.mem.eql(u8, x.type, "dir") != std.mem.eql(u8, y.type, "dir")) return std.mem.eql(u8, x.type, "dir");
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return entries.toOwnedSlice(a);
}

pub fn score(query: []const u8, candidate: []const u8) ?usize {
    if (query.len == 0) return 0;
    var qi: usize = 0;
    var points: usize = 0;
    var previous: ?usize = null;
    for (candidate, 0..) |c, i| {
        if (std.ascii.toLower(c) != std.ascii.toLower(query[qi])) continue;
        points += if (i == 0 or candidate[i - 1] == '/') @as(usize, 8) else 1;
        if (previous) |p| if (i == p + 1) {
            points += 3;
        };
        previous = i;
        qi += 1;
        if (qi == query.len) return points;
    }
    return null;
}

pub fn find(a: A, io: Io, root: []const u8, query: []const u8, limit: usize) ![]Match {
    const real = try confined(a, io, root, "");
    const dir = try Io.Dir.openDirAbsolute(io, real, .{ .iterate = true });
    defer dir.close(io);
    var found: std.ArrayList(Match) = .empty;
    var visited: usize = 0;
    try walk(a, io, dir, "", query, 0, &visited, &found);
    std.mem.sort(Match, found.items, {}, struct {
        fn less(_: void, x: Match, y: Match) bool {
            if (x.score != y.score) return x.score > y.score;
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    if (found.items.len > limit) found.shrinkRetainingCapacity(limit);
    return found.toOwnedSlice(a);
}

fn walk(a: A, io: Io, dir: Io.Dir, prefix: []const u8, query: []const u8, depth: usize, visited: *usize, found: *std.ArrayList(Match)) !void {
    if (depth >= 5 or visited.* >= 10000) return;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        visited.* += 1;
        if (visited.* > 10000) break;
        if (e.name.len == 0 or e.name[0] == '.') continue;
        const name = try std.fs.path.join(a, &.{ prefix, e.name });
        if (e.kind == .file) {
            if (score(query, name)) |rank| try found.append(a, .{ .path = name, .score = rank });
        } else if (e.kind == .directory and !std.mem.eql(u8, e.name, "node_modules") and !std.mem.eql(u8, e.name, "zig-cache") and !std.mem.eql(u8, e.name, "zig-out")) {
            const child = dir.openDir(io, e.name, .{ .iterate = true }) catch continue;
            defer child.close(io);
            try walk(a, io, child, name, query, depth + 1, visited, found);
        }
    }
}

pub fn read(a: A, io: Io, root: []const u8, path: []const u8, offset: usize, limit: usize) !Read {
    if (path.len == 0) return error.InvalidPath;
    const real = try confined(a, io, root, path);
    const stat = try Io.Dir.cwd().statFile(io, real, .{});
    if (stat.kind != .file) return error.InvalidPath;
    if (stat.size > 1024 * 1024) return error.FileTooLarge;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, real, a, .limited(1024 * 1024 + 1));
    if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) return error.BinaryFile;
    const start = @min(offset, bytes.len);
    const end = @min(bytes.len, start +| limit);
    if (!std.unicode.utf8ValidateSlice(bytes[start..end])) return error.InvalidOffset;
    return .{ .content = bytes[start..end], .size = stat.size, .offset = start };
}

test "confinement and fuzzy ordering" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/foo.zig", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/f--o--o", .data = "other" });
    try tmp.dir.symLink(io, "../", "root/outside", .{});
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const root = try std.fs.path.join(a, &.{ base, "root" });
    try std.testing.expectError(error.InvalidPath, confined(a, io, root, "../secret"));
    try std.testing.expectError(error.OutsideLocation, confined(a, io, root, "outside"));
    try std.testing.expect(score("foo", "src/foo.zig").? > score("foo", "f--o--o").?);
    const matches = try find(a, io, root, "foo", 5);
    try std.testing.expectEqualStrings("src/foo.zig", matches[0].path);
}
