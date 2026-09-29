//! Runs one hook command: `/bin/sh -c <command>` in its own process group,
//! with `input` on stdin, stdout and stderr captured separately up to a cap,
//! and a deadline after which the whole group is killed. Returned text lives
//! in `arena`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    cwd: []const u8,
    command: []const u8,
    input: []const u8 = "",
    /// The child's whole environment; null inherits ours.
    env: ?*const std.process.Environ.Map = null,
    timeout_ms: u64 = 60_000,
    /// Per stream; the rest is read and dropped.
    max_output: usize = 32 * 1024,
};

/// Longer deadlines are cut to this (nanoseconds must fit in an i64).
pub const max_timeout_ms: u64 = 7 * 24 * 60 * 60 * 1000;

pub const Output = struct {
    stdout: []const u8,
    stderr: []const u8,
    /// Exit status; null when the deadline killed it.
    exit_code: ?u8,
    timed_out: bool = false,
};

pub fn run(arena: Allocator, io: Io, opts: Options) !Output {
    if (!std.fs.path.isAbsolute(opts.cwd)) return error.RelativeWorkingDirectory;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", opts.command },
        .cwd = .{ .path = opts.cwd },
        .environ_map = opts.env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const pid = child.id.?;
    // Reaping is ours (never `child.wait`, whose cancellation forgets the
    // process): the task polls for the exit, and whatever it did not reap is
    // killed with its group and reaped here, without cancellation.
    var reaped = false;
    defer {
        _ = std.c.kill(-pid, .KILL);
        if (!reaped) reap(pid);
        // Pipes the completion task never took (it could not start).
        for ([_]?Io.File{ child.stdin, child.stdout, child.stderr }) |pipe| if (pipe) |file| file.close(io);
    }

    // The deadline covers the whole run, the exit included: a hook that
    // closes its output and keeps running is still killed on time.
    const Event = union(enum) { finished: anyerror!Output, deadline: Io.Cancelable!void };
    var storage: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.finished, complete, .{ arena, io, &child, opts, &reaped });
    try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(@intCast(@min(opts.timeout_ms, max_timeout_ms))), Io.Clock.awake });
    switch (try select.await()) {
        .finished => |result| return result,
        .deadline => |expired| {
            try expired;
            // Ends the losing task's reads and polling before it is discarded.
            _ = std.c.kill(-pid, .KILL);
            return .{ .stdout = "", .stderr = "", .exit_code = null, .timed_out = true };
        },
    }
}

fn complete(arena: Allocator, io: Io, child: *std.process.Child, opts: Options, reaped: *bool) anyerror!Output {
    var group: Io.Group = .init;
    defer group.cancel(io);
    var stdout: Capture = .{ .max = opts.max_output };
    var stderr: Capture = .{ .max = opts.max_output };
    // Each task closes its pipe, so the child no longer owns them; a pipe
    // whose task could not start is closed here.
    const stdin_pipe = child.stdin.?;
    const stdout_pipe = child.stdout.?;
    const stderr_pipe = child.stderr.?;
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    group.concurrent(io, feed, .{ io, stdin_pipe, opts.input }) catch |err| {
        for ([_]Io.File{ stdin_pipe, stdout_pipe, stderr_pipe }) |pipe| pipe.close(io);
        return err;
    };
    group.concurrent(io, Capture.drain, .{ &stdout, arena, io, stdout_pipe }) catch |err| {
        for ([_]Io.File{ stdout_pipe, stderr_pipe }) |pipe| pipe.close(io);
        return err;
    };
    group.concurrent(io, Capture.drain, .{ &stderr, arena, io, stderr_pipe }) catch |err| {
        stderr_pipe.close(io);
        return err;
    };
    try group.await(io);
    if (stdout.failure) |err| return err;
    if (stderr.failure) |err| return err;
    const status = try waitExit(io, child.id.?);
    reaped.* = true;
    const code: ?u8 = if (std.c.W.IFEXITED(status)) std.c.W.EXITSTATUS(status) else null;
    return .{ .stdout = stdout.bytes.items, .stderr = stderr.bytes.items, .exit_code = code };
}

/// Polls until `pid` exits; canceling leaves it unreaped.
fn waitExit(io: Io, pid: std.posix.pid_t) !u32 {
    var status: c_int = 0;
    while (true) {
        const found = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (found == pid) return @bitCast(status);
        if (found < 0 and std.c.errno(found) != .INTR) return error.WaitFailed;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

/// Blocks until `pid` (already killed) is reaped; a signal does not stop it.
fn reap(pid: std.posix.pid_t) void {
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return;
    }
}

/// Writes all of `input`, then closes stdin. A hook that exits without
/// reading is fine: the broken pipe ends the write.
fn feed(io: Io, file: Io.File, input: []const u8) Io.Cancelable!void {
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    writer.interface.writeAll(input) catch return;
    writer.interface.flush() catch return;
}

const Capture = struct {
    max: usize,
    bytes: std.ArrayList(u8) = .empty,
    failure: ?anyerror = null,

    fn drain(c: *Capture, arena: Allocator, io: Io, file: Io.File) Io.Cancelable!void {
        defer file.close(io);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => return,
                error.Canceled => return error.Canceled,
                else => {
                    c.failure = err;
                    return;
                },
            };
            if (n == 0) return;
            const room = c.max -| c.bytes.items.len;
            c.bytes.appendSlice(arena, chunk[0..@min(n, room)]) catch |err| {
                c.failure = err;
                return;
            };
        }
    }
};

const testing = std.testing;

test "stdin reaches the command; stdout, stderr and the exit code come back separately" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try run(arena.allocator(), testing.io, .{ .cwd = "/tmp", .command = "cat; printf oops >&2; exit 2", .input = "{\"a\":1}" });
    try testing.expectEqualStrings("{\"a\":1}", out.stdout);
    try testing.expectEqualStrings("oops", out.stderr);
    try testing.expectEqual(@as(?u8, 2), out.exit_code);
}

test "output is capped and a hook that ignores stdin still finishes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const big = try arena.allocator().alloc(u8, 256 * 1024);
    @memset(big, 'x');
    const out = try run(arena.allocator(), testing.io, .{ .cwd = "/tmp", .command = "head -c 100000 /dev/zero", .input = big, .max_output = 1000 });
    try testing.expectEqual(@as(usize, 1000), out.stdout.len);
    try testing.expectEqual(@as(?u8, 0), out.exit_code);
}

test "the deadline still applies after the command closes its output" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try run(arena.allocator(), testing.io, .{ .cwd = "/tmp", .command = "cat >/dev/null; exec >/dev/null 2>&1; sleep 5", .timeout_ms = 100 });
    try testing.expect(out.timed_out);
}

test "the deadline kills the command and its children" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = path[0..try tmp.dir.realPath(testing.io, &path)];
    const out = try run(arena.allocator(), testing.io, .{ .cwd = cwd, .command = "(sleep 1; touch escaped) & sleep 5", .timeout_ms = 50 });
    try testing.expect(out.timed_out);
    try Io.sleep(testing.io, .fromMilliseconds(1200), .awake);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "escaped", .{}));
}

test "canceling a run leaves no unreaped child" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    const Done = union(enum) { ran: anyerror!Output, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &storage);
    try select.concurrent(.ran, run, .{ arena.allocator(), io, Options{ .cwd = "/tmp", .command = "exec >/dev/null 2>&1; sleep 5" } });
    try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(100), Io.Clock.awake });
    try testing.expect(try select.await() == .deadline);
    select.cancelDiscard();
    var status: c_int = 0;
    // -1: this process has no child left to reap.
    try testing.expectEqual(@as(std.posix.pid_t, -1), std.c.waitpid(-1, &status, std.c.W.NOHANG));
}
