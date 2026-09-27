const std = @import("std");

var requested: std.atomic.Value(bool) = .init(false);

/// Signal handlers only set a lock-free flag. The server observes it and
/// joins workers before removing discovery. Ignore SIGHUP for daemon lifetime.
pub fn installTermination() void {
    requested.store(false, .release);

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onTerminate },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.HUP, &ignore, null);
}

fn onTerminate(_: std.posix.SIG) callconv(.c) void {
    requested.store(true, .release);
}

pub fn terminationRequested() bool {
    return requested.load(.acquire);
}
