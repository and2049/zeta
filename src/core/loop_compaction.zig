//! The loop's compaction steps: automatic before a model request, and on
//! request from the inbox. See compaction.zig.
const std = @import("std");
const proto = @import("proto");
const Allocator = std.mem.Allocator;
const Loop = @import("loop.zig").Loop;
const compaction = @import("compaction.zig");
const types = proto.event.types;

/// Compacts when the history the model would see no longer fits its
/// context window with the reserve kept free.
pub fn autoCompact(l: *Loop) !void {
    const settings = l.config.compaction;
    const window = l.config.options.context_window;
    if (!settings.enabled or window == 0) return;
    if (l.config.compaction_failures) |count| if (count.* >= compaction.max_failures) return;
    var scratch: std.heap.ArenaAllocator = .init(l.gpa);
    defer scratch.deinit();
    if (try compaction.contextTokens(scratch.allocator(), l.session.messages.items) + reserve(settings.reserveTokens, window) <= window) return;
    _ = try compactNow(l, .threshold, null);
}

/// Whether a request the model rejected as too long may be compacted and
/// sent once more: compaction is on and has not failed too often.
pub fn mayRecover(l: *Loop) bool {
    if (!l.config.compaction.enabled) return false;
    if (l.config.compaction_failures) |count| if (count.* >= compaction.max_failures) return false;
    return true;
}

/// The reserve actually kept free: at most a quarter of the window, so a
/// small model is not compacted on every request.
fn reserve(configured: u64, window: u64) u64 {
    return @min(configured, window / 4);
}

/// `overflow`: the model rejected a request as too long for its context.
pub const Reason = enum { manual, threshold, overflow };

/// Summarizes the older history and logs the summary; true when it did. A
/// failure is reported (`compaction.failed`) and, unless asked for, counted;
/// the run goes on.
pub fn compactNow(l: *Loop, reason: Reason, instructions: ?[]const u8) !bool {
    var scratch: std.heap.ArenaAllocator = .init(l.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    try l.emit(types.compaction_start, .{ .reason = @tagName(reason) });
    const done = summarize(l, a, reason, instructions) catch |err| {
        if (err == error.Canceled) return err;
        // Having nothing to summarize is not a failed attempt.
        if (reason != .manual and err != error.NothingToCompact) if (l.config.compaction_failures) |count| {
            count.* +|= 1;
        };
        try l.emit(types.compaction_failed, .{ .reason = @tagName(reason), .@"error" = @errorName(err) });
        return false;
    };
    if (l.config.compaction_failures) |count| count.* = 0;
    try l.emit(types.compaction_end, .{ .reason = @tagName(reason), .messageId = done.id, .tokensBefore = done.tokensBefore });
    return true;
}

const Done = struct { id: []const u8, tokensBefore: u64 };

fn summarize(l: *Loop, a: Allocator, reason: Reason, instructions: ?[]const u8) !Done {
    const log = l.session.messages.items;
    // Asked for explicitly, or after the model rejected the history as too
    // long, a short history is still summarized: all but the newest message.
    // What stays verbatim must leave room in the window for the summary.
    const settings = l.config.compaction;
    const window = l.config.options.context_window;
    const keep = if (window > 0) @min(settings.keepRecentTokens, (window - reserve(settings.reserveTokens, window)) / 2) else settings.keepRecentTokens;
    const cut = (try compaction.plan(a, log, keep)) orelse
        (if (reason != .threshold) try compaction.plan(a, log, 0) else null) orelse return error.NothingToCompact;
    const tokens_before = try compaction.contextTokens(a, log);
    const text = try compaction.request(a, try compaction.serialize(a, log, cut.summarize), cut.previous, instructions);
    const summary = try compaction.summarize(a, l.io, l.config.api, l.config.options, l.config.model_id, l.session.info.location, text);
    const buf = l.ids.next(l.io, .message);
    const id = try a.dupe(u8, buf.slice());
    try l.appendMessage(.{
        .id = id,
        .role = .user,
        .content = &.{.{ .text = summary.text }},
        .timestamp = l.now(),
        .origin = compaction.origin,
        .firstKeptId = log[cut.first_kept].id,
        .tokensBefore = tokens_before,
        .usage = summary.usage.priced(l.config.options.price),
        .provider = l.config.provider_id,
        .model = l.config.model_id,
    });
    return .{ .id = id, .tokensBefore = tokens_before };
}

test "the reserve is at most a quarter of a small window" {
    try std.testing.expectEqual(@as(u64, 16384), reserve(16384, 200_000));
    try std.testing.expectEqual(@as(u64, 2048), reserve(16384, 8192));
    try std.testing.expectEqual(@as(u64, 0), reserve(16384, 0));
}
