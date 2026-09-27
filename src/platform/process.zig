const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");

/// Starts `argv` in its own process group with stdin closed and
/// stdout/stderr appending to `log_path`. The log is not truncated here: a
/// child that loses the single-instance race must not wipe the running
/// server's log (see `resetLog`). The child is not waited for; it is
/// reparented when this process exits.
pub fn spawnDetached(io: Io, argv: []const []const u8, log_path: []const u8) !void {
    if (std.fs.path.dirname(log_path)) |dir| {
        _ = try Io.Dir.cwd().createDirPathStatus(io, dir, fs.private_dir);
    }
    const log = try openAppend(log_path);
    defer log.close(io);
    _ = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0,
    });
}

fn openAppend(path: []const u8) !Io.File {
    var buffer: [Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const fd = std.c.open(&buffer, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Empties `log_path` when it is this process's stdout. Call once the process
/// owns the server instance lock, so each started server gets a fresh log.
/// Output keeps going to the end of the file because it was opened to append.
pub fn resetLog(io: Io, log_path: []const u8) void {
    const stdout = Io.File.stdout();
    const out = stdout.stat(io) catch return;
    const file = Io.Dir.cwd().statFile(io, log_path, .{}) catch return;
    if (out.kind != .file or out.inode != file.inode) return;
    stdout.setLength(io, 0) catch {};
}

/// True if a process with this pid exists (it may belong to another user).
pub fn isAlive(pid: i64) bool {
    if (pid <= 0 or pid > std.math.maxInt(std.c.pid_t)) return false;
    if (std.c.kill(@intCast(pid), @enumFromInt(0)) == 0) return true;
    return std.c._errno().* == @intFromEnum(std.c.E.PERM);
}

test "the detached log is appended to, never truncated on open" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "server.log", .data = "running\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "server.log", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const log = try openAppend(path);
    defer log.close(io);
    var buffer: [16]u8 = undefined;
    var w = log.writer(io, &buffer);
    try w.interface.writeAll("loser\n");
    try w.interface.flush();
    const got = try tmp.dir.readFileAlloc(io, "server.log", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("running\nloser\n", got);
}

test isAlive {
    try std.testing.expect(isAlive(@intCast(std.c.getpid())));
    try std.testing.expect(!isAlive(0));
    try std.testing.expect(!isAlive(-1));
}
