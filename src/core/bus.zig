//! Event bus. Each event is encoded once into a refcounted frame and fanned
//! out to per-subscriber bounded queues. A subscriber that falls behind is
//! closed; the rest keep going.

const std = @import("std");
const proto = @import("proto");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_queue_len = 4096;

/// One encoded envelope, shared by every subscriber that received it.
pub const Frame = struct {
    refs: std.atomic.Value(u32),
    seq: u64,
    bytes: []u8,

    pub fn release(f: *Frame, gpa: Allocator) void {
        if (f.refs.fetchSub(1, .acq_rel) == 1) {
            gpa.free(f.bytes);
            gpa.destroy(f);
        }
    }
};

pub const Subscriber = struct {
    queue: Io.Queue(*Frame),
    storage: []*Frame,
    node: std.DoublyLinkedList.Node = .{},
    overflowed: bool = false,

    /// Blocks for the next frame. Null once the subscriber is closed and drained.
    /// The caller must `release` the frame.
    pub fn next(s: *Subscriber, io: Io) Io.Cancelable!?*Frame {
        return s.queue.getOne(io) catch |err| switch (err) {
            error.Closed => null,
            error.Canceled => |e| e,
        };
    }
};

pub const Event = struct {
    type: []const u8,
    session: ?[]const u8 = null,
    location: ?[]const u8 = null,
    data: []const u8 = "{}",
};

pub const Bus = struct {
    gpa: Allocator,
    io: Io,
    queue_len: usize = default_queue_len,
    mutex: Io.Mutex = .init,
    seq: u64 = 0,
    subscribers: std.DoublyLinkedList = .{},

    pub fn init(gpa: Allocator, io: Io) Bus {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(b: *Bus) void {
        std.debug.assert(b.subscribers.first == null);
    }

    pub fn subscribe(b: *Bus) Allocator.Error!*Subscriber {
        const s = try b.gpa.create(Subscriber);
        errdefer b.gpa.destroy(s);
        const storage = try b.gpa.alloc(*Frame, b.queue_len);
        s.* = .{ .queue = .init(storage), .storage = storage };
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.subscribers.append(&s.node);
        return s;
    }

    /// Call after subscribing, then fetch Runtime.snapshot. Its revision is
    /// read under the runtime state lock after copying completed messages,
    /// leased inputs, assistant draft, and pending permissions. Discard feed
    /// frames through revision and apply newer frames. A message draft covers
    /// all earlier deltas; session.inbox.updated replaces the inbox projection
    /// and permission.resolved removes an ask after revision.
    /// On queue overflow reconnect and repeat, never infer state from a gap.
    pub fn revision(b: *Bus) u64 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return b.seq;
    }

    /// Whether any subscriber is attached that could answer a permission ask.
    pub fn hasSubscribers(b: *Bus) bool {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return b.subscribers.first != null;
    }

    pub fn unsubscribe(b: *Bus, s: *Subscriber) void {
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            b.subscribers.remove(&s.node);
        }
        s.queue.close(b.io);
        var buf: [64]*Frame = undefined;
        while (true) {
            const n = s.queue.getUncancelable(b.io, &buf, 0) catch break;
            if (n == 0) break;
            for (buf[0..n]) |f| f.release(b.gpa);
        }
        b.gpa.free(s.storage);
        b.gpa.destroy(s);
    }

    pub fn publishValue(b: *Bus, ty: []const u8, session: ?[]const u8, location: ?[]const u8, data: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(b.gpa, data, .{});
        defer b.gpa.free(json);
        _ = try b.publish(.{ .type = ty, .session = session, .location = location, .data = json });
    }

    pub fn publish(b: *Bus, ev: Event) Allocator.Error!u64 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const next = b.seq + 1;
        const frame = try b.encode(next, ev);
        b.seq = next;
        defer frame.release(b.gpa);

        var it = b.subscribers.first;
        while (it) |node| : (it = node.next) {
            const s: *Subscriber = @fieldParentPtr("node", node);
            if (s.overflowed) continue;
            _ = frame.refs.fetchAdd(1, .monotonic);
            const n = s.queue.putUncancelable(b.io, &.{frame}, 0) catch 0;
            if (n == 0) {
                frame.release(b.gpa);
                s.overflowed = true;
                s.queue.close(b.io);
            }
        }
        return b.seq;
    }

    fn encode(b: *Bus, seq: u64, ev: Event) Allocator.Error!*Frame {
        var out: Io.Writer.Allocating = .init(b.gpa);
        defer out.deinit();
        const env: proto.Envelope = .{
            .seq = seq,
            .type = ev.type,
            .session = ev.session,
            .location = ev.location,
            .time = Io.Clock.real.now(b.io).toMilliseconds(),
            .data = ev.data,
        };
        env.write(&out.writer) catch return error.OutOfMemory;
        const f = try b.gpa.create(Frame);
        f.* = .{ .refs = .init(1), .seq = seq, .bytes = try out.toOwnedSlice() };
        return f;
    }
};

test "fan out to two subscribers in order" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const a = try bus.subscribe();
    const b = try bus.subscribe();

    _ = try bus.publish(.{ .type = "x.one" });
    try bus.publishValue("x.two", "ses_1", null, .{ .n = 2 });

    for ([_]*Subscriber{ a, b }) |s| {
        const f1 = (try s.next(io)).?;
        defer f1.release(gpa);
        try std.testing.expectEqual(@as(u64, 1), f1.seq);
        const f2 = (try s.next(io)).?;
        defer f2.release(gpa);
        try std.testing.expect(std.mem.indexOf(u8, f2.bytes, "\"data\":{\"n\":2}") != null);
        try std.testing.expect(std.mem.indexOf(u8, f2.bytes, "\"session\":\"ses_1\"") != null);
    }
    bus.unsubscribe(a);
    bus.unsubscribe(b);
}

test "slow subscriber is dropped, others unaffected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    bus.queue_len = 2;
    const slow = try bus.subscribe();
    bus.queue_len = 8;
    const fast = try bus.subscribe();

    for (0..3) |_| _ = try bus.publish(.{ .type = "x" });
    try std.testing.expect(slow.overflowed);
    try std.testing.expect(!fast.overflowed);

    (try slow.next(io)).?.release(gpa);
    (try slow.next(io)).?.release(gpa);
    try std.testing.expectEqual(@as(?*Frame, null), try slow.next(io));

    bus.unsubscribe(slow);
    bus.unsubscribe(fast); // releases 3 queued frames
}
