//! Connection admission and deadlines. A fixed table of slots caps concurrent
//! connections; each slot carries the deadline of the phase its connection
//! is in (waiting for a request, reading headers, reading a body). One
//! watchdog task shuts down the socket of any slot past its deadline, which
//! ends the blocked read. Handler work and streaming responses are unbounded.
const std = @import("std");
const Io = std.Io;

pub const max_connections = 64;
pub const header_ms = 10 * std.time.ms_per_s;
pub const body_ms = 60 * std.time.ms_per_s;
pub const idle_ms = 5 * std.time.ms_per_min;
const tick_ms = 250;

pub const Limits = struct {
    header_ms: i64 = header_ms,
    body_ms: i64 = body_ms,
    idle_ms: i64 = idle_ms,
};

pub const Slot = struct {
    tracker: *Tracker,
    stream: Io.net.Stream = undefined,
    used: bool = false,
    /// Awake-clock milliseconds; null while no read is bounded.
    deadline: ?i64 = null,

    pub fn waitRequest(s: *Slot) void {
        s.arm(s.tracker.limits.idle_ms);
    }

    pub fn readHeaders(s: *Slot) void {
        s.arm(s.tracker.limits.header_ms);
    }

    pub fn readBody(s: *Slot) void {
        s.arm(s.tracker.limits.body_ms);
    }

    /// The handler runs (or streams) without a deadline.
    pub fn unbounded(s: *Slot) void {
        const t = s.tracker;
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        s.deadline = null;
    }

    fn arm(s: *Slot, ms: i64) void {
        const t = s.tracker;
        const at = Io.Clock.awake.now(t.io).toMilliseconds() +| ms;
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        s.deadline = at;
    }
};

pub const Tracker = struct {
    io: Io,
    limits: Limits = .{},
    mutex: Io.Mutex = .init,
    slots: [max_connections]Slot = undefined,

    pub fn init(t: *Tracker, io: Io, limits: Limits) void {
        t.* = .{ .io = io, .limits = limits };
        for (&t.slots) |*s| s.* = .{ .tracker = t };
    }

    /// Returns null when every slot is taken. The first request is bounded
    /// by the header deadline from the moment of accept.
    pub fn admit(t: *Tracker, stream: Io.net.Stream) ?*Slot {
        const at = Io.Clock.awake.now(t.io).toMilliseconds() +| t.limits.header_ms;
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        for (&t.slots) |*s| if (!s.used) {
            s.* = .{ .tracker = t, .stream = stream, .used = true, .deadline = at };
            return s;
        };
        return null;
    }

    /// Call before closing the stream, so the watchdog never touches a
    /// descriptor that may already be reused.
    pub fn release(t: *Tracker, s: *Slot) void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        s.used = false;
        s.deadline = null;
    }

    pub fn active(t: *Tracker) usize {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        var n: usize = 0;
        for (&t.slots) |*s| n += @intFromBool(s.used);
        return n;
    }

    pub fn watchdog(t: *Tracker) Io.Cancelable!void {
        while (true) {
            try t.io.sleep(.fromMilliseconds(tick_ms), .awake);
            t.expire();
        }
    }

    fn expire(t: *Tracker) void {
        const now = Io.Clock.awake.now(t.io).toMilliseconds();
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        for (&t.slots) |*s| {
            if (!s.used) continue;
            const at = s.deadline orelse continue;
            if (now < at) continue;
            s.deadline = null;
            s.stream.shutdown(t.io, .both) catch {};
        }
    }
};

test "admission is capped and released slots are reused" {
    const io = std.testing.io;
    var tracker: Tracker = undefined;
    tracker.init(io, .{});
    const stream: Io.net.Stream = .{ .socket = .{ .handle = -1, .address = undefined } };
    var taken: [max_connections]*Slot = undefined;
    for (&taken) |*slot| slot.* = tracker.admit(stream).?;
    try std.testing.expect(tracker.admit(stream) == null);
    tracker.release(taken[3]);
    try std.testing.expect(tracker.admit(stream) == taken[3]);
    try std.testing.expectEqual(@as(usize, max_connections), tracker.active());
    for (taken) |slot| tracker.release(slot);
    try std.testing.expectEqual(@as(usize, 0), tracker.active());
}

test "an expired read deadline shuts the socket down; an unbounded slot is left alone" {
    const io = std.testing.io;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    const client_addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    const quiet = try client_addr.connect(io, .{ .mode = .stream });
    defer quiet.close(io);
    const stalled = try server.accept(io);
    defer stalled.close(io);
    const busy_client = try client_addr.connect(io, .{ .mode = .stream });
    defer busy_client.close(io);
    const busy = try server.accept(io);
    defer busy.close(io);

    var tracker: Tracker = undefined;
    tracker.init(io, .{ .header_ms = 20 });
    const stalled_slot = tracker.admit(stalled).?;
    defer tracker.release(stalled_slot);
    const busy_slot = tracker.admit(busy).?;
    defer tracker.release(busy_slot);
    busy_slot.unbounded();

    var dog = try io.concurrent(Tracker.watchdog, .{&tracker});
    defer dog.cancel(io) catch {};
    var buf: [16]u8 = undefined;
    var reader = stalled.reader(io, &buf);
    // Blocks until the watchdog shuts the socket down.
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
    try std.testing.expect(busy_slot.deadline == null);
}
