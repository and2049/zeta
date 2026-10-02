//! Questions plugins ask the user (see `plugin.ask`). Each is published as
//! `question.asked` for its project and waits for
//! `POST /questions/:id/reply`; `question.resolved` follows. With no
//! event subscriber, when the last one leaves, or when time runs out, the
//! answer is `decline`; a question the asker withdraws resolves as
//! `cancel`. Events carry the asking session when it is known. Notices
//! are published as `plugin.notice` and need no answer.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Bus = @import("bus.zig").Bus;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Action = plugin.ask.Action;
const formats = @import("question_formats.zig");

pub const Asks = struct {
    gpa: Allocator,
    io: Io,
    bus: *Bus,
    ids: *proto.id.Generator,
    mutex: Io.Mutex = .init,
    pending: std.StringHashMapUnmanaged(*Pending) = .empty,

    const Pending = struct {
        event: Io.Event = .unset,
        action: Action = .decline,
        /// Owned by the gpa once answered.
        content: ?[]u8 = null,
        question: plugin.ask.Question,
        expires_at: i64,
    };

    /// A question as clients see it: the kind's name and its fields.
    pub const Info = struct {
        id: []const u8,
        session: ?[]const u8,
        source: []const u8,
        message: []const u8,
        kind: []const u8,
        detail: ?[]const u8 = null,
        options: ?[]const plugin.ask.Option = null,
        placeholder: ?[]const u8 = null,
        secret: ?bool = null,
        schema: ?std.json.Value = null,
        expiresAt: i64,

        /// Fields of other kinds are left out rather than written as null.
        pub fn jsonStringify(self: Info, jw: anytype) !void {
            try jw.beginObject();
            inline for (@typeInfo(Info).@"struct".fields) |f| {
                const value = @field(self, f.name);
                const present = if (@typeInfo(f.type) == .optional) value != null else true;
                if (present or comptime std.mem.eql(u8, f.name, "session")) {
                    try jw.objectField(f.name);
                    try jw.write(value);
                }
            }
            try jw.endObject();
        }
    };

    /// `q` as clients see it, in `arena`; null for a form whose schema is
    /// not JSON or a choice without options (those decline at once).
    fn info(arena: Allocator, id: []const u8, q: plugin.ask.Question, expires_at: i64) !?Info {
        var out: Info = .{
            .id = try arena.dupe(u8, id),
            .session = if (q.session) |v| try arena.dupe(u8, v) else null,
            .source = try arena.dupe(u8, q.source),
            .message = try arena.dupe(u8, q.message),
            .kind = @tagName(q.kind),
            .expiresAt = expires_at,
        };
        switch (q.kind) {
            .confirm => |c| out.detail = if (c.detail) |v| try arena.dupe(u8, v) else null,
            .select => |c| {
                if (c.options.len == 0) return null;
                const options = try arena.alloc(plugin.ask.Option, c.options.len);
                for (c.options, options) |o, *d| d.* = .{ .value = try arena.dupe(u8, o.value), .label = try arena.dupe(u8, o.label), .description = try arena.dupe(u8, o.description) };
                out.options = options;
            },
            .input => |c| {
                out.placeholder = if (c.placeholder) |v| try arena.dupe(u8, v) else null;
                out.secret = c.secret;
            },
            .form => |c| out.schema = std.json.parseFromSliceLeaky(std.json.Value, arena, c.schema, .{ .allocate = .alloc_always }) catch return null,
        }
        return out;
    }

    pub fn init(gpa: Allocator, io: Io, bus: *Bus, ids: *proto.id.Generator) Asks {
        return .{ .gpa = gpa, .io = io, .bus = bus, .ids = ids };
    }

    /// Every question must have been answered or given up.
    pub fn deinit(a: *Asks) void {
        std.debug.assert(a.pending.count() == 0);
        a.pending.deinit(a.gpa);
    }

    pub fn asker(a: *Asks) plugin.ask.Asker {
        return .{ .ctx = a, .ask = askFn, .notify = notifyFn };
    }

    fn notifyFn(ctx: ?*anyopaque, n: plugin.ask.Notice) anyerror!void {
        const a: *Asks = @ptrCast(@alignCast(ctx.?));
        return a.notify(n);
    }

    pub fn notify(a: *Asks, n: plugin.ask.Notice) !void {
        try a.bus.publishValue(proto.event.types.plugin_notice, n.session, n.location, .{ .source = n.source, .message = n.message, .level = @tagName(n.level) });
    }

    fn askFn(ctx: ?*anyopaque, arena: Allocator, io: Io, q: plugin.ask.Question) anyerror!plugin.ask.Answer {
        const a: *Asks = @ptrCast(@alignCast(ctx.?));
        _ = io;
        return a.ask(arena, q);
    }

    pub fn ask(a: *Asks, arena: Allocator, q: plugin.ask.Question) !plugin.ask.Answer {
        const id = a.ids.next(a.io, .question);
        const key = try a.gpa.dupe(u8, id.slice());
        defer a.gpa.free(key);
        const ms: i64 = @intCast(@min(q.timeout_ms, std.math.maxInt(i64)));
        var pending: Pending = .{ .question = q, .expires_at = Io.Clock.real.now(a.io).toMilliseconds() +| ms };
        const shown = try info(arena, key, q, pending.expires_at) orelse return .{ .action = .decline };
        a.mutex.lockUncancelable(a.io);
        a.pending.put(a.gpa, key, &pending) catch |err| {
            a.mutex.unlock(a.io);
            return err;
        };
        a.mutex.unlock(a.io);
        defer {
            a.mutex.lockUncancelable(a.io);
            _ = a.pending.remove(key);
            const content = pending.content;
            a.mutex.unlock(a.io);
            if (content) |c| a.gpa.free(c);
            a.bus.publishValue(proto.event.types.question_resolved, q.session, q.location, .{ .id = key, .action = @tagName(pending.action) }) catch {};
        }
        try a.bus.publishValue(proto.event.types.question_asked, q.session, q.location, shown);
        // Checked after publishing: a listener leaving later reaches this
        // question through `disconnect`.
        if (!a.bus.hasSubscribers()) return .{ .action = .decline };
        const Done = union(enum) { reply: Io.Cancelable!void, deadline: Io.Cancelable!void, withdrawn: Io.Cancelable!void };
        var storage: [3]Done = undefined;
        var select: Io.Select(Done) = .init(a.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.reply, Io.Event.wait, .{ &pending.event, a.io });
        try select.concurrent(.deadline, Io.sleep, .{ a.io, Io.Duration.fromMilliseconds(ms), Io.Clock.awake });
        if (q.withdrawn) |event| try select.concurrent(.withdrawn, Io.Event.wait, .{ event, a.io });
        const unanswered: ?Action = switch (try select.await()) {
            .reply => |result| blk: {
                try result;
                break :blk null;
            },
            .deadline => |result| blk: {
                try result;
                break :blk .decline;
            },
            .withdrawn => |result| blk: {
                try result;
                break :blk .cancel;
            },
        };
        if (unanswered) |action| {
            a.mutex.lockUncancelable(a.io);
            defer a.mutex.unlock(a.io);
            if (!pending.event.isSet()) {
                pending.action = action;
                pending.event.set(a.io);
            }
        }
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        return .{ .action = pending.action, .content = if (pending.content) |c| try arena.dupe(u8, c) else null };
    }

    /// False for an unknown or already answered question.
    /// `error.InvalidContent` (the question stays open) when `accept`'s
    /// `content` (JSON text) does not fit the question (see
    /// `plugin.ask.Kind`); `problem` then says why, in `arena`.
    pub fn reply(a: *Asks, arena: Allocator, id: []const u8, action: Action, content: ?[]const u8, problem: *[]const u8) !bool {
        const copy = if (action == .accept) try a.gpa.dupe(u8, content orelse "null") else null;
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        const p = a.pending.get(id) orelse {
            if (copy) |c| a.gpa.free(c);
            return false;
        };
        if (copy) |c| if (try misfit(arena, p.question.kind, c)) |why| {
            a.gpa.free(c);
            problem.* = why;
            return error.InvalidContent;
        };
        if (p.event.isSet()) {
            if (copy) |c| a.gpa.free(c);
            return false;
        }
        p.action = action;
        p.content = copy;
        p.event.set(a.io);
        return true;
    }

    /// Why `content` does not answer a question of `kind`, or null when it
    /// does.
    fn misfit(arena: Allocator, kind: plugin.ask.Kind, content: []const u8) !?[]const u8 {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch return "content is not JSON";
        const schema = switch (kind) {
            .confirm => return null,
            .input => return if (value == .string) null else "content must be a string",
            .select => |c| {
                if (value != .string) return "content must be a string";
                for (c.options) |o| if (std.mem.eql(u8, o.value, value.string)) return null;
                return "content is not one of the options";
            },
            .form => |c| c.schema,
        };
        const shape = std.json.parseFromSliceLeaky(std.json.Value, arena, schema, .{}) catch return null;
        if (value != .object) return "content must be an object";
        const issues = try @import("schema.zig").validate(arena, shape, value);
        if (issues.len > 0) {
            const first = issues[0];
            return if (first.path.len > 0) try std.fmt.allocPrint(arena, "{s}: {s}", .{ first.path, first.message }) else first.message;
        }
        // Form schemas are flat; their string formats are checked here.
        const properties = if (shape == .object) shape.object.get("properties") orelse return null else return null;
        if (properties != .object) return null;
        var it = properties.object.iterator();
        while (it.next()) |p| {
            const format = if (p.value_ptr.* == .object) p.value_ptr.object.get("format") orelse continue else continue;
            const given = value.object.get(p.key_ptr.*) orelse continue;
            if (format != .string or given != .string) continue;
            if (!formats.fits(format.string, given.string)) return try std.fmt.allocPrint(arena, "{s}: not a valid {s}", .{ p.key_ptr.*, format.string });
        }
        return null;
    }

    /// Questions still open for `location`, in `arena`.
    pub fn list(a: *Asks, arena: Allocator, location: []const u8) ![]const Info {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        var out: std.ArrayList(Info) = .empty;
        var it = a.pending.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (p.event.isSet() or !std.mem.eql(u8, p.question.location, location)) continue;
            if (try info(arena, entry.key_ptr.*, p.question, p.expires_at)) |shown| try out.append(arena, shown);
        }
        return out.items;
    }

    /// The last event listener left: nobody can answer what is open.
    pub fn disconnect(a: *Asks) void {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        var it = a.pending.valueIterator();
        while (it.next()) |p| if (!p.*.event.isSet()) {
            p.*.action = .decline;
            p.*.event.set(a.io);
        };
    }
};

test "answers must fit the form's formats" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema: plugin.ask.Kind = .{ .form = .{ .schema = "{\"type\":\"object\",\"properties\":{\"mail\":{\"type\":\"string\",\"format\":\"email\"},\"day\":{\"type\":\"string\",\"format\":\"date\"}}}" } };
    try std.testing.expect(try Asks.misfit(a, schema, "{\"mail\":\"a@b.c\",\"day\":\"2026-09-29\"}") == null);
    try std.testing.expectEqualStrings("mail: not a valid email", (try Asks.misfit(a, schema, "{\"mail\":\"nope\"}")).?);
    try std.testing.expectEqualStrings("day: not a valid date", (try Asks.misfit(a, schema, "{\"day\":\"29/09\"}")).?);
    try std.testing.expect(try Asks.misfit(a, schema, "{\"day\":\"2026-02-30\"}") != null);
    try std.testing.expect(try Asks.misfit(a, schema, "{\"mail\":\"a@@b.c\"}") != null);
}

test "answers must fit the kind of question" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pick: plugin.ask.Kind = .{ .select = .{ .options = &.{ .{ .value = "once" }, .{ .value = "always" } } } };
    try std.testing.expect(try Asks.misfit(a, pick, "\"once\"") == null);
    try std.testing.expectEqualStrings("content is not one of the options", (try Asks.misfit(a, pick, "\"never\"")).?);
    try std.testing.expect(try Asks.misfit(a, pick, "1") != null);
    const line: plugin.ask.Kind = .{ .input = .{} };
    try std.testing.expect(try Asks.misfit(a, line, "\"text\"") == null);
    try std.testing.expect(try Asks.misfit(a, line, "{}") != null);
    try std.testing.expect(try Asks.misfit(a, .{ .confirm = .{} }, "null") == null);
    // A choice without options cannot be shown.
    const empty: plugin.ask.Question = .{ .location = "/p", .source = "t", .message = "?", .kind = .{ .select = .{ .options = &.{} } }, .timeout_ms = 1 };
    try std.testing.expect(try Asks.info(a, "que_1", empty, 0) == null);
}

test "an answer reaches the asker; without listeners it declines" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    var asks: Asks = .init(gpa, io, &bus, &ids);
    defer asks.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const q: plugin.ask.Question = .{ .location = "/p", .source = "mcp:docs", .message = "Which branch?", .kind = .{ .form = .{ .schema = "{\"type\":\"object\",\"properties\":{\"branch\":{\"type\":\"string\"}}}" } }, .timeout_ms = 5000 };
    try std.testing.expectEqual(plugin.ask.Action.decline, (try asks.ask(arena.allocator(), q)).action);

    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    const Answerer = struct {
        fn run(a: *Asks, s: *@import("bus.zig").Subscriber, t_io: Io) Io.Cancelable!void {
            while (true) {
                const frame = (s.next(t_io) catch return) orelse return;
                defer frame.release(std.testing.allocator);
                var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer scratch.deinit();
                const event = proto.event.Decoded.parse(scratch.allocator(), frame.bytes) catch return;
                if (!std.mem.eql(u8, event.type, proto.event.types.question_asked)) continue;
                const id = event.data.object.get("id").?.string;
                std.debug.assert((a.list(scratch.allocator(), "/p") catch unreachable).len == 1);
                var why: []const u8 = "";
                std.debug.assert(a.reply(scratch.allocator(), id, .accept, "{\"branch\":7}", &why) == error.InvalidContent);
                _ = a.reply(scratch.allocator(), id, .accept, "{\"branch\":\"main\"}", &why) catch return;
                return;
            }
        }
    };
    var task = try io.concurrent(Answerer.run, .{ &asks, sub, io });
    defer task.cancel(io) catch {};
    const answer = try asks.ask(arena.allocator(), q);
    try std.testing.expectEqual(plugin.ask.Action.accept, answer.action);
    try std.testing.expectEqualStrings("{\"branch\":\"main\"}", answer.content.?);
}

test {
    _ = formats;
}

/// A question asked with a listener subscribed, as a task.
const Asking = struct {
    fn run(a: *Asks, arena: Allocator, q: plugin.ask.Question) anyerror!plugin.ask.Answer {
        return a.ask(arena, q);
    }

    /// Waits until the question is open.
    fn open(a: *Asks) !void {
        while (true) {
            a.mutex.lockUncancelable(a.io);
            const n = a.pending.count();
            a.mutex.unlock(a.io);
            if (n > 0) return;
            try a.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

test "a question declines when time runs out or the last listener leaves, and cancels when withdrawn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    var asks: Asks = .init(gpa, io, &bus, &ids);
    defer asks.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const sub = try bus.subscribe();
    var subscribed = true;
    defer if (subscribed) bus.unsubscribe(sub);
    const base: plugin.ask.Question = .{ .location = "/p", .source = "mcp:docs", .message = "?", .kind = .{ .confirm = .{} }, .timeout_ms = 20, .session = "ses_1" };
    try std.testing.expectEqual(Action.decline, (try asks.ask(arena.allocator(), base)).action);

    var withdrawn: Io.Event = .unset;
    var q = base;
    q.timeout_ms = 60_000;
    q.withdrawn = &withdrawn;
    var task = try io.concurrent(Asking.run, .{ &asks, arena.allocator(), q });
    try Asking.open(&asks);
    const listed = try asks.list(arena.allocator(), "/p");
    try std.testing.expectEqualStrings("ses_1", listed[0].session.?);
    withdrawn.set(io);
    try std.testing.expectEqual(Action.cancel, (try task.await(io)).action);

    // Cancelling the asker takes its question away.
    withdrawn.reset();
    var cancelled = try io.concurrent(Asking.run, .{ &asks, arena.allocator(), q });
    try Asking.open(&asks);
    try std.testing.expectError(error.Canceled, cancelled.cancel(io));
    try std.testing.expectEqual(@as(usize, 0), asks.pending.count());

    var left = try io.concurrent(Asking.run, .{ &asks, arena.allocator(), q });
    try Asking.open(&asks);
    bus.unsubscribe(sub);
    subscribed = false;
    asks.disconnect();
    try std.testing.expectEqual(Action.decline, (try left.await(io)).action);
    try std.testing.expectEqual(@as(usize, 0), asks.pending.count());
}
