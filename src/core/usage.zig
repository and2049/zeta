//! Token and cost totals over session logs, overall and per model. A fork
//! counts only what it added after the messages it copied.
const std = @import("std");
const proto = @import("proto");
const Runtime = @import("Runtime.zig");
const Allocator = std.mem.Allocator;

pub const Totals = struct {
    input: u64 = 0,
    output: u64 = 0,
    cacheRead: u64 = 0,
    cacheWrite: u64 = 0,
    /// USD for the messages whose price was known.
    cost: f64 = 0,
    /// Messages with usage, and how many of them had no price.
    messages: usize = 0,
    unpriced: usize = 0,

    fn add(t: *Totals, u: proto.message.Usage) void {
        t.input += u.input;
        t.output += u.output;
        t.cacheRead += u.cacheRead;
        t.cacheWrite += u.cacheWrite;
        t.messages += 1;
        if (u.cost) |c| t.cost += c else t.unpriced += 1;
    }
};

pub const ModelTotals = struct { provider: []const u8, model: []const u8, totals: Totals };

pub const Report = struct {
    total: Totals = .{},
    /// Most expensive first, then by tokens.
    models: []const ModelTotals = &.{},
    sessions: usize = 0,
};

const Builder = struct {
    arena: Allocator,
    report: Report = .{},
    models: std.ArrayList(ModelTotals) = .empty,

    /// Adds `messages` of one session; `copied_through` is the id of the
    /// last message a fork copied.
    fn session(b: *Builder, messages: []const proto.Message, copied_through: ?[]const u8) !void {
        b.report.sessions += 1;
        var start: usize = 0;
        if (copied_through) |last| for (messages, 0..) |m, i| if (std.mem.eql(u8, m.id, last)) {
            start = i + 1;
            // The results of that message's calls came along too.
            while (start < messages.len and messages[start].role == .tool_result) start += 1;
            break;
        };
        for (messages[start..]) |m| {
            const u = m.usage orelse continue;
            b.report.total.add(u);
            const provider = m.provider orelse "";
            const model = m.model orelse "";
            const entry = for (b.models.items) |*e| {
                if (std.mem.eql(u8, e.provider, provider) and std.mem.eql(u8, e.model, model)) break e;
            } else blk: {
                try b.models.append(b.arena, .{ .provider = try b.arena.dupe(u8, provider), .model = try b.arena.dupe(u8, model), .totals = .{} });
                break :blk &b.models.items[b.models.items.len - 1];
            };
            entry.totals.add(u);
        }
    }

    fn finish(b: *Builder) Report {
        std.mem.sort(ModelTotals, b.models.items, {}, struct {
            fn more(_: void, x: ModelTotals, y: ModelTotals) bool {
                if (x.totals.cost != y.totals.cost) return x.totals.cost > y.totals.cost;
                return x.totals.input + x.totals.output > y.totals.input + y.totals.output;
            }
        }.more);
        b.report.models = b.models.items;
        return b.report;
    }
};

/// Totals of one session, in `arena`.
pub fn ofSession(rt: *Runtime, arena: Allocator, id: []const u8) !Report {
    var b: Builder = .{ .arena = arena };
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(id) orelse return error.SessionNotFound;
    entry.session.mutex.lockUncancelable(rt.io);
    defer entry.session.mutex.unlock(rt.io);
    try b.session(entry.session.messages.items, entry.session.info.forkedAt);
    return b.finish();
}

/// Totals of every session this runtime has (of `location`'s only, when
/// given) created since `since` (Unix ms; 0 for all), in `arena`.
pub fn ofAll(rt: *Runtime, arena: Allocator, location: ?[]const u8, since: i64) !Report {
    var b: Builder = .{ .arena = arena };
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    var it = rt.sessions.valueIterator();
    while (it.next()) |entry| {
        const s = entry.*.session;
        if (location) |filter| if (!std.mem.eql(u8, filter, s.info.location)) continue;
        if (s.info.created < since) continue;
        s.mutex.lockUncancelable(rt.io);
        defer s.mutex.unlock(rt.io);
        try b.session(s.messages.items, s.info.forkedAt);
    }
    return b.finish();
}

test "totals skip what a fork copied and sort models by cost" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]proto.Message{
        .{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{}, .provider = "p", .model = "cheap", .usage = .{ .input = 10, .output = 5, .cost = 0.01 } },
        .{ .id = "t", .role = .tool_result, .timestamp = 0, .content = &.{} },
        .{ .id = "b", .role = .assistant, .timestamp = 0, .content = &.{}, .provider = "p", .model = "dear", .usage = .{ .input = 1, .output = 1, .cost = 1 } },
        .{ .id = "c", .role = .assistant, .timestamp = 0, .content = &.{}, .provider = "p", .model = "free", .usage = .{ .input = 100 } },
    };
    var b: Builder = .{ .arena = arena.allocator() };
    try b.session(&messages, null);
    try b.session(&messages, "a");
    const r = b.finish();
    try std.testing.expectEqual(@as(usize, 2), r.sessions);
    try std.testing.expectEqual(@as(u64, 10 + 1 + 100 + 1 + 100), r.total.input);
    try std.testing.expectApproxEqAbs(@as(f64, 2.01), r.total.cost, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), r.total.unpriced);
    try std.testing.expectEqualStrings("dear", r.models[0].model);
    try std.testing.expectEqual(@as(usize, 3), r.models.len);
}
