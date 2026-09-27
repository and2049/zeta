const std = @import("std");
const Io = std.Io;

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

test isAlive {
    try std.testing.expect(isAlive(@intCast(std.c.getpid())));
    try std.testing.expect(!isAlive(0));
    try std.testing.expect(!isAlive(-1));
}
