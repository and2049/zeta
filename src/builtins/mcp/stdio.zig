//! MCP over a child process: one JSON message per line on its stdin and
//! stdout. stderr is kept as a short tail for error reports. The child runs
//! in its own process group; `shutdown` ends stdin, waits a second, then
//! kills the group. The memory stays until `destroy`, since a request on
//! another task may still be finishing with it.
const std = @import("std");
const rpc = @import("rpc.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    command: []const []const u8,
    cwd: []const u8,
    /// The child's whole environment.
    env: *const std.process.Environ.Map,
};

pub const Stdio = struct {
    gpa: Allocator,
    io: Io,
    conn: *rpc.Connection,
    child: std.process.Child,
    stdin: ?Io.File,
    write_mutex: Io.Mutex = .init,
    tasks: Io.Group = .init,
    /// Last bytes the server wrote to stderr.
    tail_mutex: Io.Mutex = .init,
    tail: [2048]u8 = undefined,
    tail_len: usize = 0,
    reaped: bool = false,

    /// `conn` must outlive the transport; its `transport` is set here.
    pub fn start(gpa: Allocator, io: Io, conn: *rpc.Connection, opts: Options) !*Stdio {
        const self = try gpa.create(Stdio);
        self.* = .{ .gpa = gpa, .io = io, .conn = conn, .child = undefined, .stdin = null };
        self.child = std.process.spawn(io, .{
            .argv = opts.command,
            .cwd = .{ .path = opts.cwd },
            .environ_map = opts.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        }) catch |err| {
            gpa.destroy(self);
            return err;
        };
        self.stdin = self.child.stdin;
        self.child.stdin = null;
        const stdout = self.child.stdout.?;
        const stderr = self.child.stderr.?;
        self.child.stdout = null;
        self.child.stderr = null;
        conn.transport = .{ .ctx = self, .send = send, .send_now = sendNow };
        self.tasks.concurrent(io, readMessages, .{ self, stdout }) catch |err| {
            stdout.close(io);
            stderr.close(io);
            self.stdin.?.close(io);
            self.kill();
            reap(self.child.id.?);
            gpa.destroy(self);
            return err;
        };
        self.tasks.concurrent(io, readErrors, .{ self, stderr }) catch |err| {
            stderr.close(io);
            self.shutdown();
            self.destroy();
            return err;
        };
        return self;
    }

    /// Stops the child; requests still waiting fail. Idempotent.
    pub fn shutdown(self: *Stdio) void {
        const io = self.io;
        // A writer blocked on a full pipe holds the lock: kill first, which
        // fails its write and frees the lock.
        if (!self.write_mutex.tryLock()) {
            self.kill();
            self.write_mutex.lockUncancelable(io);
        }
        const stdin = self.stdin;
        self.stdin = null;
        self.write_mutex.unlock(io);
        if (stdin) |file| file.close(io) else return;
        // A well-behaved server exits when its stdin closes.
        var waited: u32 = 0;
        while (waited < 100) : (waited += 1) {
            var status: c_int = 0;
            if (std.c.waitpid(self.child.id.?, &status, std.c.W.NOHANG) == self.child.id.?) {
                self.reaped = true;
                break;
            }
            io.sleep(.fromMilliseconds(10), .awake) catch break;
        }
        self.kill();
        if (!self.reaped) reap(self.child.id.?);
        self.reaped = true;
        self.tasks.cancel(io);
    }

    /// Frees the transport after `shutdown`, once nothing can use it.
    pub fn destroy(self: *Stdio) void {
        self.gpa.destroy(self);
    }

    fn kill(self: *Stdio) void {
        if (self.child.id) |pid| _ = std.c.kill(-pid, .KILL);
    }

    /// The last of the server's stderr, copied into `arena`.
    pub fn errors(self: *Stdio, arena: Allocator) ![]const u8 {
        self.tail_mutex.lockUncancelable(self.io);
        defer self.tail_mutex.unlock(self.io);
        return arena.dupe(u8, std.mem.trim(u8, self.tail[0..self.tail_len], " \t\r\n"));
    }

    fn send(ctx: *anyopaque, message: []const u8) anyerror!void {
        const self: *Stdio = @ptrCast(@alignCast(ctx));
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        const file = self.stdin orelse return error.McpDisconnected;
        var buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &buf);
        writer.interface.writeAll(message) catch return error.McpDisconnected;
        writer.interface.writeAll("\n") catch return error.McpDisconnected;
        writer.interface.flush() catch return error.McpDisconnected;
    }

    /// Writes a small message only if that cannot block: nobody else is
    /// writing and the pipe has room. Otherwise it is dropped.
    fn sendNow(ctx: *anyopaque, message: []const u8) void {
        const self: *Stdio = @ptrCast(@alignCast(ctx));
        if (message.len + 1 > 4096 or !self.write_mutex.tryLock()) return;
        defer self.write_mutex.unlock(self.io);
        const file = self.stdin orelse return;
        var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return;
        if (ready == 0) return;
        var buf: [4097]u8 = undefined;
        @memcpy(buf[0..message.len], message);
        buf[message.len] = '\n';
        _ = std.c.write(file.handle, &buf, message.len + 1);
    }

    fn readMessages(self: *Stdio, file: Io.File) Io.Cancelable!void {
        defer file.close(self.io);
        self.conn.close(try self.lines(file));
    }

    /// Hands each line to the connection; returns why reading stopped.
    fn lines(self: *Stdio, file: Io.File) Io.Cancelable![]const u8 {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = file.readStreaming(self.io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => return "the server exited",
                error.Canceled => return error.Canceled,
                else => return "reading from the server failed",
            };
            if (n == 0) return "the server exited";
            var rest = chunk[0..n];
            while (std.mem.indexOfScalar(u8, rest, '\n')) |end| {
                line.appendSlice(self.gpa, rest[0..end]) catch return "out of memory";
                const text = std.mem.trim(u8, line.items, " \t\r");
                if (text.len > 0) self.conn.receive(text);
                line.clearRetainingCapacity();
                rest = rest[end + 1 ..];
            }
            if (line.items.len + rest.len > rpc.max_message) return "a message was too large";
            line.appendSlice(self.gpa, rest) catch return "out of memory";
        }
    }

    fn readErrors(self: *Stdio, file: Io.File) Io.Cancelable!void {
        defer file.close(self.io);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = file.readStreaming(self.io, &.{&chunk}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            if (n == 0) return;
            self.tail_mutex.lockUncancelable(self.io);
            defer self.tail_mutex.unlock(self.io);
            const data = chunk[0..n];
            if (data.len >= self.tail.len) {
                @memcpy(&self.tail, data[data.len - self.tail.len ..]);
                self.tail_len = self.tail.len;
            } else {
                const keep = @min(self.tail_len, self.tail.len - data.len);
                std.mem.copyForwards(u8, self.tail[0..keep], self.tail[self.tail_len - keep .. self.tail_len]);
                @memcpy(self.tail[keep .. keep + data.len], data);
                self.tail_len = keep + data.len;
            }
        }
    }
};

const testing = std.testing;

test "messages go both ways over a child's stdio and its exit closes the connection" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var conn: rpc.Connection = .{ .gpa = testing.allocator, .io = testing.io, .transport = undefined };
    defer conn.deinit();
    // Answers the first request with a result echoing its id, then exits.
    const script =
        \\read line; id=$(printf '%s' "$line" | sed 's/.*"id":\([0-9]*\).*/\1/'); echo "starting" >&2
        \\printf '{"jsonrpc":"2.0","id":%s,"result":{"ok":true}}\n' "$id"
    ;
    const transport = try Stdio.start(testing.allocator, testing.io, &conn, .{ .command = &.{ "/bin/sh", "-c", script }, .cwd = "/tmp", .env = &env });
    defer transport.destroy();
    defer transport.shutdown();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try conn.request(arena.allocator(), "initialize", rpc.empty, 5000, null);
    try testing.expect(result.object.get("ok").?.bool);
    try testing.expectError(error.McpDisconnected, conn.request(arena.allocator(), "tools/list", rpc.empty, 5000, null));
    try testing.expectEqualStrings("starting", try transport.errors(arena.allocator()));
}

/// Blocks until `pid` (already killed) is reaped; a signal does not stop it.
fn reap(pid: std.posix.pid_t) void {
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return;
    }
}
