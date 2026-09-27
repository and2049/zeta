//! Compaction through a real loop run.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bus = @import("bus.zig").Bus;
const Session = @import("session.zig").Session;
const Inbox = @import("inbox.zig").Inbox;
const Loop = @import("loop.zig").Loop;
const compaction = @import("compaction.zig");

const Model = struct {
    summaries: usize = 0,
    replies: usize = 0,
    /// The first message of the last ordinary request.
    first_seen: [64]u8 = undefined,
    first_len: usize = 0,
    fail_summaries: bool = false,
    /// Summaries stop at the output limit.
    cut_summaries: bool = false,
    /// Ordinary requests still to reject as too long for the context.
    overflows: usize = 0,
    rejected: usize = 0,
    /// Every ordinary request named its session.
    keyed: bool = true,

    fn stream(ctx: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, req: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, req.system, compaction.system_prompt)) {
            self.summaries += 1;
            if (self.fail_summaries) {
                try sink.emit(.{ .failure = .{ .message = "no summary today" } });
                return error.ProviderHttpError;
            }
            try sink.emit(.{ .text_delta = "SUMMARY" });
            try sink.emit(.{ .done = if (self.cut_summaries) .length else .stop });
            return;
        }
        if (req.session_id == null) self.keyed = false;
        if (self.overflows > 0) {
            self.overflows -= 1;
            self.rejected += 1;
            try sink.emit(.{ .failure = .{ .message = "HTTP 400: prompt is too long", .status = 400, .overflow = true } });
            return error.ProviderHttpError;
        }
        self.replies += 1;
        const text = req.messages[0].content[0].text;
        self.first_len = @min(text.len, self.first_seen.len);
        @memcpy(self.first_seen[0..self.first_len], text[0..self.first_len]);
        try sink.emit(.{ .text_delta = "reply" });
        try sink.emit(.{ .done = .stop });
    }
};

fn fixture(gpa: Allocator, io: Io, base: []const u8, id: []const u8) !*Session {
    const session = try Session.create(gpa, io, base, id, "/p");
    const big = "word " ** 200; // about 250 tokens
    const history = [_]struct { id: []const u8, role: proto.message.Role }{
        .{ .id = "msg_u1", .role = .user }, .{ .id = "msg_a1", .role = .assistant },
        .{ .id = "msg_u2", .role = .user }, .{ .id = "msg_a2", .role = .assistant },
    };
    for (history) |h| try session.append(.{ .id = h.id, .role = h.role, .timestamp = 0, .content = &.{.{ .text = big }} });
    return session;
}

fn loopFor(gpa: Allocator, io: Io, bus: *Bus, ids: *proto.id.Generator, session: *Session, inbox: *Inbox, model: *Model, failures: *u8) Loop {
    return .{
        .gpa = gpa,
        .io = io,
        .bus = bus,
        .ids = ids,
        .session = session,
        .inbox = inbox,
        .config = .{
            .api = .{ .id = "fake", .ctx = model, .stream = Model.stream },
            .options = .{ .context_window = 1000 },
            .provider_id = "p",
            .model_id = "m",
            .system = "",
            .compaction = .{ .reserveTokens = 200, .keepRecentTokens = 300 },
            .compaction_failures = failures,
        },
    };
}

test "a long history is compacted before the request and the model sees the summary first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try fixture(gpa, io, base, "ses_auto");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_go", "go on", .queue);
    var model: Model = .{};
    var failures: u8 = 0;
    var loop = loopFor(gpa, io, &bus, &ids, session, &inbox, &model, &failures);
    try loop.run();

    try std.testing.expectEqual(@as(usize, 1), model.summaries);
    try std.testing.expectEqual(@as(usize, 1), model.replies);
    try std.testing.expectEqualStrings("SUMMARY", model.first_seen[0..model.first_len]);
    const log = session.messages.items;
    const summary = log[log.len - 2];
    try std.testing.expect(compaction.isSummary(summary));
    try std.testing.expect(summary.tokensBefore.? > 800);
    try std.testing.expectEqualStrings("reply", log[log.len - 1].content[0].text);
    // What the model sees now is small again: no second compaction.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expect(try compaction.contextTokens(arena.allocator(), log) < 800);
}

test "a queued compaction runs without a model reply; repeated failures stop automatic ones" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try fixture(gpa, io, base, "ses_manual");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.pushCompact("msg_compact", "keep the file names");
    var model: Model = .{};
    var failures: u8 = 0;
    var loop = loopFor(gpa, io, &bus, &ids, session, &inbox, &model, &failures);
    loop.config.options.context_window = 0;
    try loop.run();
    try std.testing.expectEqual(@as(usize, 1), model.summaries);
    try std.testing.expectEqual(@as(usize, 0), model.replies);
    try std.testing.expect(compaction.isSummary(session.messages.items[session.messages.items.len - 1]));
    try std.testing.expect(inbox.isEmpty());

    // Automatic compaction that keeps failing gives up after three tries.
    model.fail_summaries = true;
    loop.config.options.context_window = 300;
    for (0..4) |i| {
        var id: [16]u8 = undefined;
        try inbox.push(try std.fmt.bufPrint(&id, "msg_next{d}", .{i}), "word " ** 400, .queue);
        loop.run() catch {};
    }
    try std.testing.expectEqual(@as(u8, compaction.max_failures), failures);
    try std.testing.expectEqual(@as(usize, 1 + compaction.max_failures), model.summaries);
}

test "a summary cut off at the output limit is not used" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try fixture(gpa, io, base, "ses_cut");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.pushCompact("msg_compact", "");
    var model: Model = .{ .cut_summaries = true };
    var failures: u8 = 0;
    var loop = loopFor(gpa, io, &bus, &ids, session, &inbox, &model, &failures);
    try loop.run();
    try std.testing.expectEqual(@as(usize, 1), model.summaries);
    for (session.messages.items) |m| try std.testing.expect(!compaction.isSummary(m));
}

test "a request rejected as too long is compacted and sent once more" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    var failures: u8 = 0;

    // The window is unknown, so only the rejection triggers compaction.
    const recovered = try fixture(gpa, io, base, "ses_overflow");
    defer recovered.destroy(gpa, io);
    try inbox.push("msg_go", "go on", .queue);
    var model: Model = .{ .overflows = 1 };
    var loop = loopFor(gpa, io, &bus, &ids, recovered, &inbox, &model, &failures);
    loop.config.options.context_window = 0;
    try loop.run();
    try std.testing.expectEqual(@as(usize, 1), model.rejected);
    try std.testing.expectEqual(@as(usize, 1), model.summaries);
    try std.testing.expectEqual(@as(usize, 1), model.replies);
    try std.testing.expect(model.keyed);
    try std.testing.expectEqualStrings("SUMMARY", model.first_seen[0..model.first_len]);
    const log = recovered.messages.items;
    // The rejected attempt is not logged: user prompt, summary, reply.
    try std.testing.expectEqualStrings("go on", log[log.len - 3].content[0].text);
    try std.testing.expect(compaction.isSummary(log[log.len - 2]));
    try std.testing.expectEqual(proto.message.StopReason.stop, log[log.len - 1].stopReason.?);

    // Rejected again after compacting: the error is logged and the run ends.
    const failed = try fixture(gpa, io, base, "ses_overflow_again");
    defer failed.destroy(gpa, io);
    try inbox.push("msg_go2", "go on", .queue);
    model = .{ .overflows = 5 };
    loop = loopFor(gpa, io, &bus, &ids, failed, &inbox, &model, &failures);
    loop.config.options.context_window = 0;
    loop.run() catch {};
    try std.testing.expectEqual(@as(usize, 2), model.rejected);
    try std.testing.expectEqual(@as(usize, 1), model.summaries);
    const last = failed.messages.items[failed.messages.items.len - 1];
    try std.testing.expectEqual(proto.message.StopReason.@"error", last.stopReason.?);
    try std.testing.expectEqualStrings("HTTP 400: prompt is too long", last.errorMessage.?);
    try std.testing.expect(compaction.isSummary(failed.messages.items[failed.messages.items.len - 2]));
}

test "when compacting after a rejection fails, the withdrawn draft is started again and logged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var ids: proto.id.Generator = .{};
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    var failures: u8 = 0;
    const session = try fixture(gpa, io, base, "ses_overflow_failed");
    defer session.destroy(gpa, io);
    try inbox.push("msg_go", "go on", .queue);
    var model: Model = .{ .overflows = 1, .fail_summaries = true };
    var loop = loopFor(gpa, io, &bus, &ids, session, &inbox, &model, &failures);
    loop.config.options.context_window = 0;
    loop.run() catch {};
    const last = session.messages.items[session.messages.items.len - 1];
    try std.testing.expectEqual(proto.message.StopReason.@"error", last.stopReason.?);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var seen: std.ArrayList([]const u8) = .empty;
    while (true) {
        const frame = (try sub.next(io)).?;
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, proto.event.types.agent_end)) break;
        const id = if (event.data.object.get("messageId")) |v| v.string else if (event.data.object.get("message")) |m| m.object.get("id").?.string else continue;
        if (std.mem.eql(u8, id, last.id) and std.mem.startsWith(u8, event.type, "message.")) try seen.append(arena.allocator(), try arena.allocator().dupe(u8, event.type));
    }
    const want = [_][]const u8{ "message.start", "message.cancelled", "message.start", "message.end" };
    try std.testing.expectEqual(want.len, seen.items.len);
    for (want, seen.items) |w, got| try std.testing.expectEqualStrings(w, got);
}
