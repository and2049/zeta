//! Compaction: once the history a model would see grows past its context
//! window minus a reserve (or on request), the older part is summarized by
//! the same model and the summary is appended to the log as a user message
//! with `origin: "compaction"` and `firstKeptId`. Nothing is rewritten: the
//! model then sees the summary followed by the messages from `firstKeptId`
//! on (see `visible`).
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Message = proto.Message;

pub const Settings = @import("config.zig").Compaction;

pub const origin = "compaction";

/// Consecutive failures after which a session stops compacting on its own.
pub const max_failures = 3;

/// Characters a tool result keeps in the text that is summarized.
const tool_result_chars = 2000;

pub fn isSummary(m: Message) bool {
    const o = m.origin orelse return false;
    return std.mem.eql(u8, o, origin);
}

/// What the model sees of `messages`: the last summary, then the messages
/// from its `firstKeptId` on, without earlier summaries. Unchanged when
/// there is none. Slices into `messages` or `arena`.
pub fn visible(arena: Allocator, messages: []const Message) ![]const Message {
    const last = lastSummary(messages) orelse return messages;
    const first = keptIndex(messages, last) orelse last + 1;
    var out: std.ArrayList(Message) = .empty;
    try out.append(arena, messages[last]);
    for (messages[first..], first..) |m, i| if (i != last and !isSummary(m)) try out.append(arena, m);
    return out.items;
}

fn lastSummary(messages: []const Message) ?usize {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (isSummary(messages[i])) return i;
    }
    return null;
}

fn keptIndex(messages: []const Message, summary: usize) ?usize {
    const id = messages[summary].firstKeptId orelse return null;
    for (messages[0..summary], 0..) |m, i| if (std.mem.eql(u8, m.id, id)) return i;
    return null;
}

/// Rough token count: four characters a token, 1200 for an image.
pub fn estimate(m: Message) u64 {
    var chars: u64 = 0;
    for (m.content) |part| switch (part) {
        .text => |t| chars += t.len,
        .thinking => |t| chars += t.text.len,
        .tool_call => |c| chars += c.name.len + c.arguments.len,
        .image => chars += 4800,
    };
    return chars / 4 + 4;
}

/// Tokens the model would see of `log`: the last reported usage of a reply
/// logged after the latest summary (its input plus output), and an
/// estimate of everything after that reply. Replies kept from before the
/// summary reported the old, longer context, so they are only estimated.
pub fn contextTokens(arena: Allocator, log: []const Message) !u64 {
    const seen = try visible(arena, log);
    const fresh = if (lastSummary(log)) |s| log.len - s - 1 else seen.len;
    var i = seen.len;
    var after: u64 = 0;
    while (i > 0) {
        i -= 1;
        const m = seen[i];
        if (seen.len - i <= fresh and m.role == .assistant) if (m.usage) |u| if (u.input + u.cacheRead > 0) {
            return u.input + u.cacheRead + u.cacheWrite + u.output + after;
        };
        after += estimate(m);
    }
    return after;
}

pub const Plan = struct {
    /// Log indexes of the messages to summarize.
    summarize: []const usize,
    /// Log index of the first message kept verbatim.
    first_kept: usize,
    /// The summary being replaced, if any, for continuity.
    previous: ?[]const u8,
};

/// Where to cut `messages` (the log) so that about `keep_recent` tokens stay
/// verbatim. The cut is at a user or assistant message, never between a
/// tool call and its result. Null when there is nothing to summarize.
pub fn plan(arena: Allocator, messages: []const Message, keep_recent: u64) !?Plan {
    const last = lastSummary(messages);
    const start = if (last) |s| keptIndex(messages, s) orelse s + 1 else 0;
    var candidates: std.ArrayList(usize) = .empty;
    for (messages[start..], start..) |m, i| if (!isSummary(m)) try candidates.append(arena, i);
    if (candidates.items.len < 2) return null;
    var kept: u64 = 0;
    var cut: usize = candidates.items.len;
    while (cut > 0) {
        const cost = estimate(messages[candidates.items[cut - 1]]);
        if (kept + cost > keep_recent) break;
        kept += cost;
        cut -= 1;
    }
    // Keep at least the newest message, and start the kept part at a user
    // or assistant message: a tool result stays with its call. Forward when
    // there is such a message later; otherwise back to the call that owns
    // the final results, even if that keeps more than asked.
    if (cut == candidates.items.len) cut -= 1;
    var forward = cut;
    while (forward < candidates.items.len and messages[candidates.items[forward]].role == .tool_result) forward += 1;
    if (forward < candidates.items.len) {
        cut = forward;
    } else while (cut > 0 and messages[candidates.items[cut]].role == .tool_result) cut -= 1;
    if (cut == 0) return null;
    return .{
        .summarize = candidates.items[0..cut],
        .first_kept = candidates.items[cut],
        .previous = if (last) |s| try messages[s].text(arena) else null,
    };
}

/// The conversation as plain text, so the summarizing model reads it
/// rather than continuing it.
pub fn serialize(arena: Allocator, messages: []const Message, indexes: []const usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    for (indexes) |i| {
        const m = messages[i];
        for (m.content) |part| switch (part) {
            .text => |t| switch (m.role) {
                .user => try w.print("[User]: {s}\n", .{t}),
                .assistant => try w.print("[Assistant]: {s}\n", .{t}),
                .tool_result => {
                    var cut = @min(t.len, tool_result_chars);
                    // Never inside a UTF-8 sequence.
                    while (cut > 0 and cut < t.len and (t[cut] & 0xc0) == 0x80) cut -= 1;
                    try w.print("[Tool result]: {s}", .{t[0..cut]});
                    if (cut < t.len) try w.print(" [... {d} more characters]", .{t.len - cut});
                    try w.writeAll("\n");
                },
            },
            .thinking => |t| try w.print("[Assistant thinking]: {s}\n", .{t.text}),
            .tool_call => |c| try w.print("[Assistant tool call]: {s}({s})\n", .{ c.name, c.arguments }),
            .image => try w.writeAll("[Image]\n"),
        };
    }
    return out.written();
}

pub const system_prompt =
    \\You summarize a coding session so it can continue with less context. You do not continue the conversation and you do not call tools.
;

const format =
    \\Write a summary that lets the work continue without the original messages, in this format:
    \\
    \\## Goal
    \\[What the user is trying to accomplish]
    \\
    \\## Constraints & Preferences
    \\- [Requirements the user stated]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed work]
    \\### In Progress
    \\- [ ] [Current work]
    \\### Blocked
    \\- [Problems, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Why]
    \\
    \\## Next Steps
    \\1. [What should happen next]
    \\
    \\## Critical Context
    \\- [Paths, names, values and errors needed to continue]
;

/// The request text for summarizing `conversation`.
pub fn request(arena: Allocator, conversation: []const u8, previous: ?[]const u8, instructions: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (previous) |p| try w.print("<previous-summary>\n{s}\n</previous-summary>\n\n", .{p});
    try w.print("<conversation>\n{s}</conversation>\n\n", .{conversation});
    if (instructions) |text| if (text.len > 0) try w.print("Focus on: {s}\n\n", .{text});
    try w.writeAll(format);
    return out.written();
}

pub const Summary = struct { text: []const u8, usage: proto.message.Usage };

const Collector = struct {
    arena: Allocator,
    text: std.ArrayList(u8) = .empty,
    usage: proto.message.Usage = .{},
    failure: ?[]const u8 = null,
    stop: ?proto.message.StopReason = null,

    fn event(ctx: *anyopaque, e: plugin.provider.Event) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        switch (e) {
            .text_delta => |t| try self.text.appendSlice(self.arena, t),
            .usage => |u| self.usage = u,
            .failure => |f| self.failure = try self.arena.dupe(u8, f.message),
            .done => |reason| self.stop = reason,
            else => {},
        }
    }
};

/// Asks the model for a summary. Only a reply that ended normally counts:
/// a summary cut off at the output limit would hide history it never
/// covered. The text lives in `arena`.
pub fn summarize(arena: Allocator, io: Io, api: plugin.provider.Api, options: plugin.provider.Options, model: []const u8, location: []const u8, text: []const u8) !Summary {
    var collector: Collector = .{ .arena = arena };
    const prompt: Message = .{ .id = "compaction-request", .role = .user, .timestamp = 0, .content = &.{.{ .text = text }} };
    api.stream(api.ctx, arena, io, options, .{ .model = model, .location = location, .system = system_prompt, .messages = &.{prompt} }, .{ .ctx = &collector, .onEvent = Collector.event }) catch |err| {
        if (collector.failure) |message| std.log.warn("compaction: {s}", .{message});
        return err;
    };
    if (collector.stop != .stop) return error.SummaryIncomplete;
    const summary = std.mem.trim(u8, collector.text.items, " \t\r\n");
    if (summary.len == 0) return error.EmptySummary;
    return .{ .text = summary, .usage = collector.usage };
}

const testing = std.testing;

var parts: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn msg(id: []const u8, role: proto.message.Role, text: []const u8) Message {
    const content = parts.allocator().alloc(proto.message.Content, 1) catch @panic("OOM");
    content[0] = .{ .text = text };
    return .{ .id = id, .role = role, .timestamp = 0, .content = content };
}

test "visible history is the last summary and what it kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var summary = msg("s", .user, "summary");
    summary.origin = origin;
    summary.firstKeptId = "u2";
    const log = [_]Message{ msg("u1", .user, "old"), msg("a1", .assistant, "old reply"), msg("u2", .user, "kept"), msg("a2", .assistant, "kept reply"), summary, msg("u3", .user, "new") };
    const seen = try visible(arena.allocator(), &log);
    const ids = [_][]const u8{ "s", "u2", "a2", "u3" };
    try testing.expectEqual(ids.len, seen.len);
    for (ids, seen) |id, m| try testing.expectEqualStrings(id, m.id);
    try testing.expectEqual(@as(usize, 2), (try visible(arena.allocator(), log[0..2])).len);
}

test "the cut keeps recent history and never separates a tool result from its call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const big = "x" ** 400; // about 100 tokens
    const log = [_]Message{
        msg("u1", .user, big),
        msg("a1", .assistant, big),
        msg("t1", .tool_result, big),
        msg("a2", .assistant, big),
        msg("t2", .tool_result, big),
        msg("u2", .user, "short"),
    };
    const p = (try plan(arena.allocator(), &log, 250)).?;
    try testing.expectEqualStrings("a2", log[p.first_kept].id);
    try testing.expectEqual(@as(usize, 3), p.summarize.len);
    try testing.expect(p.previous == null);
    try testing.expect(try plan(arena.allocator(), log[0..1], 10) == null);
    const text = try serialize(arena.allocator(), &log, p.summarize);
    try testing.expect(std.mem.startsWith(u8, text, "[User]: xxx"));
    try testing.expect(std.mem.indexOf(u8, text, "[Tool result]: ") != null);
}

test "context tokens start from the last reported usage after the latest summary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var reply = msg("a", .assistant, "hi");
    reply.usage = .{ .input = 1000, .output = 50 };
    const log = [_]Message{ msg("u", .user, "x" ** 4000), reply, msg("t", .tool_result, "y" ** 400) };
    try testing.expectEqual(@as(u64, 1000 + 50 + 104), try contextTokens(a, &log));
    try testing.expectEqual(@as(u64, 1004), try contextTokens(a, log[0..1]));
    // The kept reply's usage measured the context before the summary.
    var summary = msg("s", .user, "short summary");
    summary.origin = origin;
    summary.firstKeptId = "a";
    const compacted = [_]Message{ log[0], reply, log[2], summary };
    try testing.expectEqual(estimate(summary) + estimate(reply) + estimate(log[2]), try contextTokens(a, &compacted));
}

test "a history ending in a long tool batch keeps the whole batch with its call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const big = "x" ** 400;
    const log = [_]Message{
        msg("u1", .user, big),
        msg("a1", .assistant, big),
        msg("u2", .user, "go"),
        msg("a2", .assistant, "calling"),
        msg("t1", .tool_result, big),
        msg("t2", .tool_result, big),
    };
    const p = (try plan(arena.allocator(), &log, 150)).?;
    try testing.expectEqualStrings("a2", log[p.first_kept].id);
    try testing.expectEqual(@as(usize, 3), p.summarize.len);
}

test "tool output is cut on a character boundary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = ("a" ** (tool_result_chars - 1)) ++ "é" ++ "tail";
    const log = [_]Message{msg("t", .tool_result, text)};
    const out = try serialize(arena.allocator(), &log, &.{0});
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.indexOf(u8, out, "é") == null);
}
