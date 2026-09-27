//! Transient, fail-closed approval broker for `ask` permission decisions.
//! Request/rule strings are borrowed for the duration of evaluate; session
//! allowances and pending IDs are owned by the broker until deinit.
//! Initialize Broker with runtime's bus and ID generator, then deinit only
//! after its workers (including any blocked evaluations) are cancelled.
const std = @import("std");
const proto = @import("proto");
const Bus = @import("bus.zig").Bus;
const permissions = @import("permissions.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Rule = permissions.Rule;
const Effect = permissions.Effect;
const Reply = permissions.Reply;
const Request = permissions.Request;
const decide = permissions.decide;

pub const Broker = struct {
    gpa: Allocator,
    io: Io,
    bus: *Bus,
    ids: *proto.id.Generator,
    /// Runtime's state lock, when attached. Lock order is state -> broker ->
    /// bus; snapshot uses the same order for a coherent revision watermark.
    state_mutex: ?*Io.Mutex = null,
    mutex: Io.Mutex = .init,
    pending: std.StringHashMapUnmanaged(*Pending) = .empty,
    allowances: std.ArrayList(Allowance) = .empty,

    const Pending = struct {
        event: Io.Event = .unset,
        answer: Reply = .deny,
        expires_at: i64,
        session: []const u8,
        action: []const u8,
        pattern: []const u8,
        tool_call_id: ?[]const u8,
    };
    pub const PendingInfo = struct {
        id: []const u8,
        action: []const u8,
        pattern: []const u8,
        toolCallId: ?[]const u8,
        expiresAt: i64,
    };

    /// Copies pending asks into caller's arena. Excludes answered requests.
    pub fn snapshot(b: *Broker, arena: Allocator, session: []const u8) ![]PendingInfo {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var result: std.ArrayList(PendingInfo) = .empty;
        var it = b.pending.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (p.event.isSet() or !std.mem.eql(u8, p.session, session)) continue;
            try result.append(arena, .{
                .id = try arena.dupe(u8, entry.key_ptr.*),
                .action = try arena.dupe(u8, p.action),
                .pattern = try arena.dupe(u8, p.pattern),
                .toolCallId = if (p.tool_call_id) |id| try arena.dupe(u8, id) else null,
                .expiresAt = p.expires_at,
            });
        }
        return result.items;
    }
    const Allowance = struct {
        session: []u8,
        action: []u8,
        pattern: []u8,
    };

    pub fn init(gpa: Allocator, io: Io, bus: *Bus, ids: *proto.id.Generator) Broker {
        return .{ .gpa = gpa, .io = io, .bus = bus, .ids = ids };
    }

    /// Cancel all waiters before deinitializing the broker.
    pub fn deinit(b: *Broker) void {
        std.debug.assert(b.pending.count() == 0);
        b.pending.deinit(b.gpa);
        for (b.allowances.items) |item| {
            b.gpa.free(item.session);
            b.gpa.free(item.action);
            b.gpa.free(item.pattern);
        }
        b.allowances.deinit(b.gpa);
    }

    /// A timeout or cancellation denies and removes the pending request.
    /// `timeout_ms` is the tool's configured timeout (120000 by default).
    /// Current rules decide first; a remembered `allow_session` only answers
    /// what would otherwise be an ask, so a later deny rule still applies.
    /// With no event subscriber nobody can answer, so an ask denies at once.
    pub fn evaluate(b: *Broker, req: Request, agent: []const Rule, config: []const Rule, session: []const Rule, timeout_ms: u64) !Effect {
        const effect = decide(req, agent, config, session);
        if (effect != .ask) return effect;
        if (b.allowed(req)) return .allow;

        const id = b.ids.next(b.io, .permission);
        const key = try b.gpa.dupe(u8, id.slice());
        defer b.gpa.free(key);
        const ms: i64 = @intCast(@min(timeout_ms, std.math.maxInt(i64)));
        const expires_at = std.math.add(i64, Io.Clock.real.now(b.io).toMilliseconds(), ms) catch std.math.maxInt(i64);
        var pending: Pending = .{ .expires_at = expires_at, .session = req.session, .action = req.action, .pattern = req.pattern, .tool_call_id = req.tool_call_id };
        if (b.state_mutex) |mutex| mutex.lockUncancelable(b.io);
        b.mutex.lockUncancelable(b.io);
        b.pending.put(b.gpa, key, &pending) catch |err| {
            b.mutex.unlock(b.io);
            if (b.state_mutex) |mutex| mutex.unlock(b.io);
            return err;
        };
        b.mutex.unlock(b.io);
        const asked = b.bus.publishValue(proto.event.types.permission_asked, req.session, req.location, .{
            .id = key,
            .action = req.action,
            .pattern = req.pattern,
            .toolCallId = req.tool_call_id,
            .timeoutMs = timeout_ms,
            .expiresAt = expires_at,
        });
        if (b.state_mutex) |mutex| mutex.unlock(b.io);
        defer {
            if (b.state_mutex) |mutex| mutex.lockUncancelable(b.io);
            b.mutex.lockUncancelable(b.io);
            _ = b.pending.remove(key);
            b.mutex.unlock(b.io);
            b.bus.publishValue(proto.event.types.permission_resolved, req.session, req.location, .{
                .id = key,
                .reply = @tagName(pending.answer),
            }) catch {};
            if (b.state_mutex) |mutex| mutex.unlock(b.io);
        }
        try asked;
        // Checked after registering: a listener leaving later reaches this
        // request through disconnect().
        if (!b.bus.hasSubscribers()) return .deny;

        const Done = union(enum) { reply: Io.Cancelable!void, deadline: Io.Cancelable!void };
        var storage: [2]Done = undefined;
        var select: Io.Select(Done) = .init(b.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.reply, Io.Event.wait, .{ &pending.event, b.io });
        const remaining = @max(0, expires_at -| Io.Clock.real.now(b.io).toMilliseconds());
        try select.concurrent(.deadline, Io.sleep, .{ b.io, Io.Duration.fromMilliseconds(remaining), Io.Clock.awake });
        switch (try select.await()) {
            .reply => |result| try result,
            .deadline => |result| {
                try result;
                return .deny;
            },
        }
        b.mutex.lockUncancelable(b.io);
        const answer = pending.answer;
        b.mutex.unlock(b.io);
        if (answer == .allow_session) try b.remember(req);
        return if (answer == .deny) .deny else .allow;
    }

    /// A remembered `allow_session` answers what would be an ask.
    pub fn remembered(b: *Broker, req: Request) bool {
        return b.allowed(req);
    }

    fn allowed(b: *Broker, req: Request) bool {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        for (b.allowances.items) |item| {
            if (std.mem.eql(u8, item.session, req.session) and std.mem.eql(u8, item.action, req.action) and std.mem.eql(u8, item.pattern, req.pattern)) return true;
        }
        return false;
    }

    fn remember(b: *Broker, req: Request) !void {
        const s = try b.gpa.dupe(u8, req.session);
        errdefer b.gpa.free(s);
        const a = try b.gpa.dupe(u8, req.action);
        errdefer b.gpa.free(a);
        const p = try b.gpa.dupe(u8, req.pattern);
        errdefer b.gpa.free(p);
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        try b.allowances.append(b.gpa, .{ .session = s, .action = a, .pattern = p });
    }

    /// False means unknown or already answered; duplicate replies cannot change a decision.
    pub fn reply(b: *Broker, id: []const u8, answer: Reply) bool {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const p = b.pending.get(id) orelse return false;
        if (p.event.isSet()) return false;
        if (Io.Clock.real.now(b.io).toMilliseconds() >= p.expires_at) {
            p.answer = .deny;
            p.event.set(b.io);
            return false;
        }
        p.answer = answer;
        p.event.set(b.io);
        return true;
    }

    /// Invoked if the last event listener disconnects; no unattended ask stays open.
    pub fn disconnect(b: *Broker) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var iter = b.pending.valueIterator();
        while (iter.next()) |p| {
            if (!p.*.event.isSet()) {
                p.*.answer = .deny;
                p.*.event.set(b.io);
            }
        }
    }

    pub fn clearSession(b: *Broker, session: []const u8) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var i: usize = 0;
        while (i < b.allowances.items.len) {
            const item = b.allowances.items[i];
            if (!std.mem.eql(u8, item.session, session)) {
                i += 1;
                continue;
            }
            _ = b.allowances.swapRemove(i);
            b.gpa.free(item.session);
            b.gpa.free(item.action);
            b.gpa.free(item.pattern);
        }
    }
};
test "reply expires and session allowance is cleared" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    var broker: Broker = .init(gpa, io, &bus, &ids);
    defer broker.deinit();
    try std.testing.expect(!broker.reply("missing", .allow_once));
    const request: Request = .{ .session = "ses_1", .location = "/repo", .action = "shell", .pattern = "ls" };
    const ask = [_]Rule{.{ .action = "shell", .pattern = "*", .effect = .ask }};
    try std.testing.expectEqual(Effect.deny, try broker.evaluate(request, &.{}, &ask, &.{}, 0));
    try std.testing.expectEqual(@as(usize, 0), broker.pending.count());
    try broker.remember(request);
    try std.testing.expectEqual(Effect.allow, try broker.evaluate(request, &.{}, &ask, &.{}, 0));
    broker.clearSession("ses_1");
    try std.testing.expectEqual(Effect.deny, try broker.evaluate(request, &.{}, &ask, &.{}, 0));
}

test "session allowance never overrides a deny rule; unattended asks deny at once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    var broker: Broker = .init(gpa, io, &bus, &ids);
    defer broker.deinit();
    const request: Request = .{ .session = "ses_1", .location = "/repo", .action = "shell", .pattern = "rm x" };
    try broker.remember(request);
    const deny = [_]Rule{.{ .action = "shell", .pattern = "rm *", .effect = .deny }};
    try std.testing.expectEqual(Effect.deny, try broker.evaluate(request, &.{}, &deny, &.{}, 120_000));
    // No subscriber can answer: an ask denies without waiting for the deadline.
    const ask = [_]Rule{.{ .action = "shell", .pattern = "*", .effect = .ask }};
    const other: Request = .{ .session = "ses_1", .location = "/repo", .action = "shell", .pattern = "ls" };
    try std.testing.expectEqual(Effect.deny, try broker.evaluate(other, &.{}, &ask, &.{}, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), broker.pending.count());
}

test "allow session remembers only its session, duplicate replies rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var ids: proto.id.Generator = .{};
    var broker: Broker = .init(gpa, io, &bus, &ids);
    defer broker.deinit();
    const ask = [_]Rule{.{ .action = "shell", .pattern = "*", .effect = .ask }};
    const request: Request = .{ .session = "ses_1", .location = "/repo", .action = "shell", .pattern = "ls" };
    const Task = struct {
        broker: *Broker,
        request: Request,
        ask: []const Rule,
        effect: Effect = .deny,
        failure: ?anyerror = null,
        fn run(t: *@This()) Io.Cancelable!void {
            t.effect = t.broker.evaluate(t.request, &.{}, t.ask, &.{}, 120_000) catch |err| {
                t.failure = err;
                if (err == error.Canceled) return error.Canceled;
                return;
            };
        }
    };
    var task: Task = .{ .broker = &broker, .request = request, .ask = &ask };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Task.run, .{&task});
    const frame = (try sub.next(io)).?;
    defer frame.release(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
    try std.testing.expectEqual(@as(i64, 120_000), event.data.object.get("timeoutMs").?.integer);
    try std.testing.expect(event.data.object.get("expiresAt").?.integer >= event.time);
    const id = event.data.object.get("id").?.string;
    try std.testing.expect(broker.reply(id, .allow_session));
    try std.testing.expect(!broker.reply(id, .deny));
    try group.await(io);
    if (task.failure) |err| return err;
    try std.testing.expectEqual(Effect.allow, task.effect);
    try std.testing.expect(!broker.reply(id, .allow_once));
    try std.testing.expectEqual(Effect.allow, try broker.evaluate(request, &.{}, &ask, &.{}, 0));
    broker.clearSession(request.session);
    try std.testing.expectEqual(Effect.deny, try broker.evaluate(request, &.{}, &ask, &.{}, 0));
}
