const std = @import("std");
const Io = std.Io;

pub const private_dir: Io.File.Permissions = .fromMode(0o700);
pub const private_file: Io.File.Permissions = .fromMode(0o600);

/// Writes `bytes` to `dir_path/name` via a temp file + rename, so readers
/// never see a partial file. The file is 0600; missing parent dirs are
/// created 0700.
pub fn writePrivateAtomic(io: Io, dir_path: []const u8, name: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, dir_path, private_dir);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    var af = try dir.createFileAtomic(io, name, .{ .permissions = private_file, .replace = true });
    defer af.deinit(io);
    var buf: [4096]u8 = undefined;
    var w = af.file.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
    try af.replace(io);
}

/// Replaces `path` via a temp file + rename: readers never see a partial
/// file, and a failed write leaves the old contents. An existing file keeps
/// its mode, and a symlink keeps pointing at its (updated) target. Missing
/// parent directories are created 0755. `scratch` holds the resolved path.
pub fn writeAtomic(io: Io, scratch: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const target: ?[:0]u8 = cwd.realPathFileAlloc(io, path, scratch) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    defer if (target) |resolved| scratch.free(resolved);
    const real: []const u8 = if (target) |resolved| resolved else path;
    const existing: ?Io.File.Stat = if (target != null) try cwd.statFile(io, real, .{}) else null;
    const dir_path = std.fs.path.dirname(real) orelse ".";
    _ = try cwd.createDirPathStatus(io, dir_path, .fromMode(0o755));
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    var af = try dir.createFileAtomic(io, std.fs.path.basename(real), .{ .replace = true });
    defer af.deinit(io);
    var buf: [4096]u8 = undefined;
    var w = af.file.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
    // The creation mode is filtered by the umask; restore the exact one.
    if (existing) |stat| try af.file.setPermissions(io, stat.permissions);
    try af.replace(io);
}

test "writeAtomic keeps the mode of an existing file and the symlink to it" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "script.sh", .data = "old", .flags = .{ .permissions = .fromMode(0o751) } });
    try tmp.dir.symLink(io, "script.sh", "link.sh", .{});

    const link = try std.fs.path.join(a, &.{ base, "link.sh" });
    defer a.free(link);
    try writeAtomic(io, a, link, "new");
    var target_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("script.sh", target_buf[0..try tmp.dir.readLink(io, "link.sh", &target_buf)]);
    const contents = try tmp.dir.readFileAlloc(io, "script.sh", a, .limited(64));
    defer a.free(contents);
    try std.testing.expectEqualStrings("new", contents);
    const stat = try tmp.dir.statFile(io, "script.sh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o751), stat.permissions.toMode() & 0o777);

    const fresh = try std.fs.path.join(a, &.{ base, "nested", "fresh.txt" });
    defer a.free(fresh);
    try writeAtomic(io, a, fresh, "created");
    const created = try tmp.dir.readFileAlloc(io, "nested/fresh.txt", a, .limited(64));
    defer a.free(created);
    try std.testing.expectEqualStrings("created", created);
}

/// Reads a whole file, or null if it doesn't exist.
pub fn readFileIfExists(io: Io, gpa: std.mem.Allocator, path: []const u8, limit: usize) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

test "writePrivateAtomic creates 0600 file in 0700 dir and replaces it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ base_buf[0..base_len], "a", "b" });
    defer std.testing.allocator.free(dir_path);

    try writePrivateAtomic(io, dir_path, "f.json", "one");
    try writePrivateAtomic(io, dir_path, "f.json", "two");

    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "f.json" });
    defer std.testing.allocator.free(path);
    const got = (try readFileIfExists(io, std.testing.allocator, path, 1024)).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("two", got);

    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(?[]u8, null), try readFileIfExists(io, std.testing.allocator, "/nonexistent/zeta", 10));
}
