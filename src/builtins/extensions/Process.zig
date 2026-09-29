//! One extension process and its NDJSON channel: requests with their
//! events and response, calls from the extension, and the heartbeat. The
//! first message must be `register`. The process runs in its own group with
//! stderr going to a log file; `shutdown` sends `shutdown`, closes stdin,
//! waits a second and kills the group. The memory stays until `destroy`,
//! since a request on another task may still be finishing.
const Process = @This();
const inbound = @import("process_inbound.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

pub const max_line = 16 * 1024 * 1024;
pub const ping_ms = 10_000;
pub const dead_ms = 30_000;

pub const Options = struct {
    argv: []const []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    /// Receives stderr; truncated.
    log_path: []const u8,
};

/// Answers a call from the extension: the result as JSON text in `arena`,
/// or an error whose name is sent back.
pub const Calls = struct {
    ctx: ?*anyopaque = null,
    answer: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, method: []const u8, params: Value) anyerror![]const u8,
};

/// Told once when the process is gone for good (exit, protocol error,
/// silence), with the reason. Not called by `stop`.
pub const Lost = struct {
    ctx: ?*anyopaque = null,
    lost: *const fn (ctx: ?*anyopaque, reason: []const u8) void,
};

/// Receives the events of one request as they arrive.
pub const Events = struct {
    ctx: ?*anyopaque = null,
    event: *const fn (ctx: ?*anyopaque, event: Value) anyerror!void,
};

pub const Failure = struct {
    message: []const u8 = "",
    retryable: bool = false,
    overflow: bool = false,
};

pub const Message = struct {
    kind: enum { event, response },
    /// JSON text owned by the gpa: the event, or the result or error.
    body: []u8,
    is_error: bool = false,
    retryable: bool = false,
    overflow: bool = false,
};

pub const Waiter = struct {
    storage: [64]Message = undefined,
    queue: Io.Queue(Message) = undefined,
    /// The request holds one; the reader holds one while delivering.
    refs: std.atomic.Value(u32) = .init(1),
};

gpa: Allocator,
io: Io,
child: std.process.Child,
pid: std.posix.pid_t,
stdin: ?Io.File,
write_mutex: Io.Mutex = .init,
mutex: Io.Mutex = .init,
next_id: u64 = 1,
waiters: std.StringHashMapUnmanaged(*Waiter) = .empty,
/// Reader and heartbeat.
tasks: Io.Group = .init,
/// Calls from the extension being answered. `shutdown` leaves them (an
/// answer may need locks the shutdown's caller holds); `quiesce` and
/// `destroy` join them.
call_tasks: Io.Group = .init,
calls: Calls,
lost: Lost,
/// Set once: the first message, which must be `register` (JSON, gpa).
registration: ?[]u8 = null,
registered: Io.Event = .unset,
/// Awake-clock milliseconds of the last message from the extension.
last_seen: std.atomic.Value(i64),
gone: ?[]const u8 = null,
stopping: bool = false,

pub fn start(gpa: Allocator, io: Io, opts: Options, calls: Calls, lost: Lost) !*Process {
    const log = try Io.Dir.cwd().createFile(io, opts.log_path, .{ .truncate = true });
    defer log.close(io);
    const p = try gpa.create(Process);
    const child = std.process.spawn(io, .{
        .argv = opts.argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = opts.env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .{ .file = log },
        .pgid = 0,
    }) catch |err| {
        gpa.destroy(p);
        return err;
    };
    const stdout = child.stdout.?;
    p.* = .{
        .gpa = gpa,
        .io = io,
        .child = child,
        .pid = child.id.?,
        .stdin = child.stdin,
        .calls = calls,
        .lost = lost,
        .last_seen = .init(Io.Clock.awake.now(io).toMilliseconds()),
    };
    p.child.stdin = null;
    p.child.stdout = null;
    p.tasks.concurrent(io, inbound.readLoop, .{ p, stdout }) catch |err| {
        stdout.close(io);
        p.stdin.?.close(io);
        p.kill();
        gpa.destroy(p);
        return err;
    };
    p.tasks.concurrent(io, heartbeat, .{p}) catch |err| {
        p.shutdown();
        p.destroy();
        return err;
    };
    return p;
}

/// Waits up to `ms` for the `register` message; its JSON is gpa-owned by
/// the process.
pub fn awaitRegistration(p: *Process, ms: u64) ![]const u8 {
    const Done = union(enum) { registered: Io.Cancelable!void, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(p.io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.registered, Io.Event.wait, .{ &p.registered, p.io });
    try select.concurrent(.deadline, Io.sleep, .{ p.io, Io.Duration.fromMilliseconds(@intCast(ms)), Io.Clock.awake });
    _ = try select.await();
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    if (p.registration) |r| return r;
    std.log.warn("extension: no register message: {s}", .{p.gone orelse "timed out"});
    return if (p.gone != null) error.ExtensionExited else error.ExtensionRegisterTimeout;
}

/// Stops the process; requests still waiting fail. Idempotent.
pub fn shutdown(p: *Process) void {
    const io = p.io;
    p.mutex.lockUncancelable(io);
    const again = p.stopping;
    p.stopping = true;
    p.mutex.unlock(io);
    if (again) return;
    _ = p.sendNow("{\"type\":\"shutdown\"}");
    // A writer blocked on a full pipe holds the lock: kill first, which
    // fails its write and frees the lock.
    if (!p.write_mutex.tryLock()) {
        p.kill();
        p.write_mutex.lockUncancelable(io);
    }
    if (p.stdin) |file| file.close(io);
    p.stdin = null;
    p.write_mutex.unlock(io);
    // Give it a second to exit on its own.
    var waited: u32 = 0;
    while (waited < 100) : (waited += 1) {
        var status: c_int = 0;
        if (std.c.waitpid(p.pid, &status, std.c.W.NOHANG) == p.pid) break;
        io.sleep(.fromMilliseconds(10), .awake) catch break;
    } else p.kill();
    p.kill();
    p.tasks.cancel(io);
    p.closeWaiters("stopped");
}

/// Waits for calls from the extension still being answered.
pub fn quiesce(p: *Process) void {
    p.call_tasks.cancel(p.io);
}

/// Frees a process after `shutdown`, once no request can still use it.
pub fn destroy(p: *Process) void {
    p.quiesce();
    if (p.registration) |r| p.gpa.free(r);
    p.waiters.deinit(p.gpa);
    p.gpa.destroy(p);
}

fn kill(p: *Process) void {
    _ = std.c.kill(-p.pid, .KILL);
    var status: c_int = 0;
    while (std.c.waitpid(p.pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return;
    }
}

/// Writes a small message only if that cannot block: nobody else is
/// writing and the pipe has room. False when it was dropped.
fn sendNow(p: *Process, message: []const u8) bool {
    if (message.len + 1 > 4096 or !p.write_mutex.tryLock()) return false;
    defer p.write_mutex.unlock(p.io);
    const file = p.stdin orelse return false;
    var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.OUT, .revents = 0 }};
    if ((std.posix.poll(&fds, 0) catch return false) == 0) return false;
    var buf: [4097]u8 = undefined;
    @memcpy(buf[0..message.len], message);
    buf[message.len] = '\n';
    return std.c.write(file.handle, &buf, message.len + 1) == message.len + 1;
}

/// Sends one message (a JSON object without the newline).
pub fn send(p: *Process, message: []const u8) !void {
    try p.write_mutex.lock(p.io);
    defer p.write_mutex.unlock(p.io);
    const file = p.stdin orelse return error.ExtensionGone;
    var buf: [4096]u8 = undefined;
    var writer = file.writerStreaming(p.io, &buf);
    // A frame cut off midway would garble the next one: the channel ends.
    errdefer _ = std.c.kill(-p.pid, .KILL);
    writer.interface.writeAll(message) catch return error.ExtensionGone;
    writer.interface.writeAll("\n") catch return error.ExtensionGone;
    writer.interface.flush() catch return error.ExtensionGone;
}

/// Sends a request and waits for its response, handing events to
/// `events`. `idle_ms` bounds the wait for each next message. A response
/// error is `error.ExtensionError` with `failure` set; the result is parsed
/// into `arena`.
pub fn request(p: *Process, arena: Allocator, method: []const u8, params: anytype, idle_ms: u64, events: ?Events, failure: ?*Failure) !Value {
    const waiter = try p.gpa.create(Waiter);
    waiter.* = .{};
    waiter.queue = .init(&waiter.storage);
    var id_buf: [24]u8 = undefined;
    const id = blk: {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.gone != null or p.stopping) {
            p.gpa.destroy(waiter);
            return error.ExtensionGone;
        }
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{p.next_id}) catch unreachable;
        p.next_id += 1;
        p.waiters.put(p.gpa, id, waiter) catch |err| {
            p.gpa.destroy(waiter);
            return err;
        };
        break :blk id;
    };
    defer {
        p.mutex.lockUncancelable(p.io);
        _ = p.waiters.remove(id);
        p.mutex.unlock(p.io);
        // Late messages are refused rather than waiting for room.
        waiter.queue.close(p.io);
        p.release(waiter);
    }
    try p.send(try std.json.Stringify.valueAlloc(arena, .{ .type = "request", .id = id, .method = method, .params = params }, .{}));
    while (true) {
        const message = p.next(waiter, idle_ms) catch |err| {
            if (err == error.Canceled or err == error.ExtensionTimeout) {
                var buf: [64]u8 = undefined;
                _ = p.sendNow(std.fmt.bufPrint(&buf, "{{\"type\":\"cancel\",\"id\":\"{s}\"}}", .{id}) catch unreachable);
            }
            return err;
        };
        defer p.gpa.free(message.body);
        const value = try std.json.parseFromSliceLeaky(Value, arena, message.body, .{ .allocate = .alloc_always });
        switch (message.kind) {
            .event => if (events) |sink| try sink.event(sink.ctx, value),
            .response => {
                if (!message.is_error) return value;
                if (failure) |out| out.* = .{ .message = if (value == .string) value.string else "extension error", .retryable = message.retryable, .overflow = message.overflow };
                return error.ExtensionError;
            },
        }
    }
}

/// Drops a reference to `waiter`; the last one frees it and anything still
/// queued.
pub fn release(p: *Process, waiter: *Waiter) void {
    if (waiter.refs.fetchSub(1, .acq_rel) != 1) return;
    var leftover: [1]Message = undefined;
    waiter.queue.close(p.io);
    while ((waiter.queue.getUncancelable(p.io, &leftover, 0) catch 0) == 1) p.gpa.free(leftover[0].body);
    p.gpa.destroy(waiter);
}

/// The next message for `waiter`, waiting at most `idle_ms`.
fn next(p: *Process, waiter: *Waiter, idle_ms: u64) !Message {
    const Done = union(enum) { message: (Io.QueueClosedError || Io.Cancelable)!Message, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(p.io, &storage);
    // A message taken by the losing branch still owns its body.
    defer while (select.cancel()) |late| switch (late) {
        .message => |got| if (got) |m| p.gpa.free(m.body) else |_| {},
        .deadline => {},
    };
    try select.concurrent(.message, Io.Queue(Message).getOne, .{ &waiter.queue, p.io });
    try select.concurrent(.deadline, Io.sleep, .{ p.io, Io.Duration.fromMilliseconds(@intCast(@min(idle_ms, 7 * 24 * 3600 * 1000))), Io.Clock.awake });
    return switch (try select.await()) {
        .message => |got| got catch |err| switch (err) {
            error.Canceled => error.Canceled,
            error.Closed => error.ExtensionGone,
        },
        .deadline => |slept| blk: {
            try slept;
            break :blk error.ExtensionTimeout;
        },
    };
}

fn heartbeat(p: *Process) Io.Cancelable!void {
    while (true) {
        try p.io.sleep(.fromMilliseconds(ping_ms), .awake);
        const silent = Io.Clock.awake.now(p.io).toMilliseconds() - p.last_seen.load(.monotonic);
        if (silent > dead_ms) {
            p.mutex.lockUncancelable(p.io);
            const quiet = p.stopping or p.gone != null;
            if (p.gone == null) p.gone = "the extension stopped answering";
            p.mutex.unlock(p.io);
            if (quiet) return;
            // The reader ends once the group is gone, and reports it lost.
            _ = std.c.kill(-p.pid, .KILL);
            return;
        }
        // Never blocks: a stuck writer must not stop the silence check.
        _ = p.sendNow("{\"type\":\"ping\"}");
    }
}

pub fn closeWaiters(p: *Process, reason: []const u8) void {
    _ = reason;
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    var it = p.waiters.valueIterator();
    while (it.next()) |waiter| waiter.*.queue.close(p.io);
}
