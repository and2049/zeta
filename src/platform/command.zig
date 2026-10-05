//! Bounded bash execution. The caller owns the returned output (allocated in arena).
//! A separate process group allows cancellation to terminate shell children too.
const std = @import("std");
const Io = std.Io;

pub const Output = struct {
    text: []const u8,
    truncated: bool,
    term: std.process.Child.Term,
    timed_out: bool = false,
    /// Ended through its `Stop`.
    stopped: bool = false,
};

/// Lets another task end a running command early while keeping what it
/// printed. Must outlive the `runStoppable` call it is passed to.
pub const Stop = struct {
    group: std.atomic.Value(std.posix.pid_t) = .init(0),
    requested: std.atomic.Value(bool) = .init(false),

    /// Kills the command and its children; before the command has started
    /// it is killed as soon as it does.
    pub fn request(s: *Stop) void {
        s.requested.store(true, .release);
        const pid = s.group.load(.acquire);
        if (pid > 0) killGroup(pid);
    }
};

const Capture = struct { text: []const u8, truncated: bool };

fn capture(arena: std.mem.Allocator, io: Io, pipe: Io.File) !Capture {
    // Retain only the tail. Drain everything, even after reaching the bound.
    var bytes: [50 * 1024]u8 = undefined;
    var len: usize = 0;
    var truncated = false;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pipe.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) break;
        if (n >= bytes.len) {
            @memcpy(&bytes, chunk[n - bytes.len .. n]);
            len = bytes.len;
            truncated = true;
        } else {
            const drop = (len + n) -| bytes.len;
            if (drop != 0) {
                std.mem.copyForwards(u8, bytes[0 .. len - drop], bytes[drop..len]);
                len -= drop;
                truncated = true;
            }
            @memcpy(bytes[len .. len + n], chunk[0..n]);
            len += n;
        }
    }
    var start: usize = len;
    var lines: usize = 0;
    while (start > 0) {
        start -= 1;
        if (bytes[start] == '\n' and start + 1 < len) {
            lines += 1;
            if (lines == 2000) {
                start += 1;
                truncated = true;
                break;
            }
        }
    }
    if (lines < 2000) start = 0;
    // A byte-bounded tail may begin inside a character; start at the next one.
    if (truncated) while (start < len and (bytes[start] & 0xc0) == 0x80) : (start += 1) {};
    return .{ .text = try arena.dupe(u8, bytes[start..len]), .truncated = truncated };
}

fn killGroup(pid: std.posix.pid_t) void {
    // pgid=0 on spawn creates a fresh group whose id is the child's pid.
    _ = std.c.kill(-pid, .KILL);
}

/// Execute bash -c in `cwd`. Optional command timeout is in milliseconds;
/// the dispatcher also has an outer deadline. Both and caller cancellation
/// run the same group-kill/reap cleanup. stderr is merged into stdout in
/// arrival order; output is bounded to 50 KiB and 2000 trailing lines.
pub fn run(arena: std.mem.Allocator, io: Io, cwd: []const u8, script: []const u8, timeout_ms: ?u64) !Output {
    return runStoppable(arena, io, cwd, script, timeout_ms, null);
}

/// `run`, ended early by `stop.request()`: the output so far is returned
/// with `stopped` set.
pub fn runStoppable(arena: std.mem.Allocator, io: Io, cwd: []const u8, script: []const u8, timeout_ms: ?u64, stop: ?*Stop) !Output {
    if (!std.fs.path.isAbsolute(cwd)) return error.RelativeWorkingDirectory;
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    const reader: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const writer: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer reader.close(io);
    var writer_open = true;
    defer if (writer_open) writer.close(io);
    // Only the child's duped stdout/stderr should survive exec. Otherwise a
    // background process with redirected output keeps our original write fd
    // open and prevents EOF indefinitely.
    for (fds) |fd| {
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) == -1) return error.PipeFailed;
    }
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/bash", "-c", script },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .{ .file = writer },
        .stderr = .{ .file = writer },
        .pgid = 0,
    });
    const pgid = child.id.?;
    writer.close(io);
    writer_open = false;
    // Always kill the process group, even after the leader exits: a background
    // child can close its inherited pipe and otherwise survive a successful run.
    defer {
        if (stop) |s| s.group.store(0, .release);
        killGroup(pgid);
        child.kill(io);
    }
    if (stop) |s| {
        s.group.store(pgid, .release);
        if (s.requested.load(.acquire)) killGroup(pgid);
    }

    var data: Capture = undefined;
    var timed_out = false;
    if (timeout_ms) |ms| {
        const Event = union(enum) { finished: anyerror!Capture, deadline: Io.Cancelable!void };
        var storage: [2]Event = undefined;
        var select: Io.Select(Event) = .init(io, &storage);
        // Canceled reads settle before pipe and process cleanup.
        defer select.cancelDiscard();
        try select.concurrent(.finished, capture, .{ arena, io, reader });
        try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))), Io.Clock.awake });
        data = switch (try select.await()) {
            .finished => |result| try result,
            .deadline => |expired| blk: {
                try expired;
                timed_out = true;
                break :blk .{ .text = "", .truncated = false };
            },
        };
        if (timed_out) {
            killGroup(pgid);
            const term = try child.wait(io);
            return .{ .text = data.text, .truncated = data.truncated, .term = term, .timed_out = true };
        }
    } else data = try capture(arena, io, reader);
    const term = try child.wait(io);
    return .{ .text = data.text, .truncated = data.truncated, .term = term, .stopped = if (stop) |s| s.requested.load(.acquire) else false };
}

test "working directory, merged stderr and nonzero status" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = path[0..try tmp.dir.realPath(io, &path)];
    const result = try run(std.testing.allocator, io, cwd, "pwd; printf error >&2; exit 7", null);
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(std.mem.startsWith(u8, result.text, cwd));
    try std.testing.expect(std.mem.endsWith(u8, result.text, "error"));
    try std.testing.expectEqual(@as(u8, 7), result.term.exited);
}

test "capture retains bounded tail by bytes and lines" {
    const io = std.testing.io;
    const result = try run(std.testing.allocator, io, "/tmp", "yes x | head -n 3000; head -c 100000 /dev/zero | tr '\\0' z", null);
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.truncated);
    try std.testing.expect(result.text.len <= 50 * 1024);
    try std.testing.expectEqual(@as(u8, 'z'), result.text[result.text.len - 1]);
}

test "a byte-bounded tail starts on a character boundary" {
    const io = std.testing.io;
    // 40000 three-byte characters: the last 50 KiB starts one byte into a
    // character, so its two continuation bytes are dropped.
    const result = try run(std.testing.allocator, io, "/tmp", "head -c 40000 /dev/zero | tr '\\0' a | sed 's/a/\u{20ac}/g'", null);
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
    try std.testing.expectEqual(@as(usize, 50 * 1024 - 2), result.text.len);
}

test "timeout kills descendant process group" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = path[0..try tmp.dir.realPath(io, &path)];
    const result = try run(std.testing.allocator, io, cwd, "(sleep 2; touch escaped) & wait", 40);
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.timed_out);
    try Io.sleep(io, .fromMilliseconds(2100), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "escaped", .{}));
}

test "successful shell does not orphan background child with redirected output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = path[0..try tmp.dir.realPath(io, &path)];
    const result = try run(std.testing.allocator, io, cwd, "(sleep 2; touch escaped) >/dev/null 2>&1 & echo complete", null);
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqualStrings("complete\n", result.text);
    try Io.sleep(io, .fromMilliseconds(2100), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "escaped", .{}));
}

test "a stop request ends the command and keeps what it printed" {
    const io = std.testing.io;
    var stop: Stop = .{};
    const Event = union(enum) { command: anyerror!Output, wait: Io.Cancelable!void };
    var storage: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.command, runStoppable, .{ std.testing.allocator, io, "/tmp", "echo before; sleep 30; echo after", @as(?u64, null), &stop });
    try select.concurrent(.wait, Io.sleep, .{ io, Io.Duration.fromMilliseconds(150), Io.Clock.awake });
    try std.testing.expect(try select.await() == .wait);
    stop.request();
    const result = try (try select.await()).command;
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.stopped);
    try std.testing.expectEqualStrings("before\n", result.text);
    // Asked before the command starts: it ends at once.
    var early: Stop = .{};
    early.request();
    const none = try runStoppable(std.testing.allocator, io, "/tmp", "sleep 30", null, &early);
    defer std.testing.allocator.free(none.text);
    try std.testing.expect(none.stopped);
}

test "outer cancellation kills descendants" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = path[0..try tmp.dir.realPath(io, &path)];
    const Event = union(enum) { command: anyerror!Output, deadline: Io.Cancelable!void };
    var storage: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &storage);
    try select.concurrent(.command, run, .{ std.testing.allocator, io, cwd, "(sleep 2; touch escaped) & wait", @as(?u64, null) });
    try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(40), Io.Clock.awake });
    const event = try select.await();
    try std.testing.expect(event == .deadline);
    select.cancelDiscard();
    try Io.sleep(io, .fromMilliseconds(2100), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "escaped", .{}));
}

test "a deadline does not hold up a command that finished, even when tasks cannot run in parallel" {
    // With no spare threads an async task runs inline; a deadline started
    // that way would sleep out its whole duration after the command ended.
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const started = Io.Clock.awake.now(io).toMilliseconds();
    const result = try run(std.testing.allocator, io, "/tmp", "echo done", 10_000);
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqualStrings("done\n", result.text);
    try std.testing.expect(Io.Clock.awake.now(io).toMilliseconds() - started < 5_000);
}
