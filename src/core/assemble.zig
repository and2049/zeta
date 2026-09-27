//! Builds an assistant message from provider stream events, publishing a
//! `message.part.delta` for each piece as it arrives.

const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Content = proto.message.Content;
const Bus = @import("bus.zig").Bus;

pub const Assembler = struct {
    arena: Allocator,
    bus: *Bus,
    session_id: []const u8,
    location: []const u8,
    message_id: []const u8,
    io: Io = undefined,
    state_mutex: ?*Io.Mutex = null,
    inflight: ?*?proto.Message = null,

    blocks: std.ArrayList(Block) = .empty,
    /// Provider tool-call index → block index.
    tool_slots: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    usage: proto.message.Usage = .{},
    stop: ?proto.message.StopReason = null,
    /// The last failure the provider reported; its message is arena-owned.
    failure: ?plugin.provider.Failure = null,

    const Block = union(enum) {
        text: std.ArrayList(u8),
        thinking: struct { text: std.ArrayList(u8) = .empty, signature: ?[]const u8 = null },
        tool_call: struct { id: []const u8, name: []const u8, arguments: std.ArrayList(u8) },
    };

    pub fn sink(a: *Assembler) plugin.provider.Sink {
        return .{ .ctx = a, .onEvent = onEvent };
    }

    fn onEvent(ctx: *anyopaque, event: plugin.provider.Event) anyerror!void {
        const a: *Assembler = @ptrCast(@alignCast(ctx));
        if (a.state_mutex) |mutex| mutex.lockUncancelable(a.io);
        defer if (a.state_mutex) |mutex| mutex.unlock(a.io);
        switch (event) {
            .text_delta => |d| try a.appendText(.text, d),
            .thinking_delta => |d| try a.appendText(.thinking, d),
            .thinking_signature => |sig| {
                const i = if (a.openThinking()) |open| open else i: {
                    try a.blocks.append(a.arena, .{ .thinking = .{} });
                    // Keeps client block indexes aligned with ours.
                    try a.publishDelta(a.blocks.items.len - 1, "thinking", "");
                    break :i a.blocks.items.len - 1;
                };
                a.blocks.items[i].thinking.signature = try a.arena.dupe(u8, sig);
            },
            .tool_call_start => |t| {
                if (a.tool_slots.get(t.index)) |i| {
                    // Identity may arrive after the first delta; fill in
                    // fields that are still empty, never overwrite them.
                    const call = &a.blocks.items[i].tool_call;
                    if (call.id.len == 0 and t.id.len > 0) call.id = try a.arena.dupe(u8, t.id);
                    if (call.name.len == 0 and t.name.len > 0) {
                        call.name = try a.arena.dupe(u8, t.name);
                        try a.publishDelta(i, "toolCall", t.name);
                    }
                } else {
                    const i = try a.openToolCall(t.index, t.id, t.name);
                    try a.publishDelta(i, "toolCall", t.name);
                }
            },
            .tool_call_delta => |t| {
                const i = a.tool_slots.get(t.index) orelse i: {
                    const opened = try a.openToolCall(t.index, "", "");
                    try a.publishDelta(opened, "toolCall", "");
                    break :i opened;
                };
                try a.blocks.items[i].tool_call.arguments.appendSlice(a.arena, t.arguments);
                try a.publishDelta(i, "toolCallArguments", t.arguments);
            },
            .usage => |u| a.usage = u,
            .done => |r| a.stop = r,
            .failure => |f| {
                var copy = f;
                copy.message = try a.arena.dupe(u8, f.message);
                a.failure = copy;
            },
        }
        if (a.inflight) |slot| if (slot.*) |*draft| {
            draft.usage = a.usage;
        };
    }

    fn openToolCall(a: *Assembler, index: u32, id: []const u8, name: []const u8) !usize {
        try a.blocks.append(a.arena, .{ .tool_call = .{
            .id = try a.arena.dupe(u8, id),
            .name = try a.arena.dupe(u8, name),
            .arguments = .empty,
        } });
        try a.tool_slots.put(a.arena, index, a.blocks.items.len - 1);
        return a.blocks.items.len - 1;
    }

    /// The last block, if it is reasoning that has not been signed yet.
    fn openThinking(a: *Assembler) ?usize {
        const n = a.blocks.items.len;
        if (n == 0) return null;
        const last = a.blocks.items[n - 1];
        return if (last == .thinking and last.thinking.signature == null) n - 1 else null;
    }

    fn appendText(a: *Assembler, comptime kind: enum { text, thinking }, delta: []const u8) !void {
        if (delta.len == 0) return;
        const n = a.blocks.items.len;
        const i = switch (kind) {
            .text => if (n > 0 and a.blocks.items[n - 1] == .text) n - 1 else null,
            .thinking => a.openThinking(),
        } orelse i: {
            try a.blocks.append(a.arena, switch (kind) {
                .text => .{ .text = .empty },
                .thinking => .{ .thinking = .{} },
            });
            break :i n;
        };
        const bytes = switch (kind) {
            .text => &a.blocks.items[i].text,
            .thinking => &a.blocks.items[i].thinking.text,
        };
        try bytes.appendSlice(a.arena, delta);
        try a.publishDelta(i, @tagName(kind), delta);
    }

    fn publishDelta(a: *Assembler, index: usize, kind: []const u8, delta: []const u8) !void {
        if (a.inflight) |slot| if (slot.*) |*draft| {
            draft.content = try a.content();
        };
        try a.bus.publishValue(proto.event.types.message_part_delta, a.session_id, a.location, .{
            .messageId = a.message_id,
            .index = index,
            .kind = kind,
            .delta = delta,
        });
    }

    /// Something of the reply reached clients, so it cannot be retried.
    pub fn streamed(a: *const Assembler) bool {
        return a.blocks.items.len > 0;
    }

    /// Forgets a failed attempt that streamed nothing, before a retry.
    pub fn clearFailure(a: *Assembler) void {
        a.failure = null;
        a.stop = null;
        a.usage = .{};
    }

    /// The content so far, as message content. Slices point into the arena.
    pub fn content(a: *Assembler) ![]const Content {
        const out = try a.arena.alloc(Content, a.blocks.items.len);
        for (a.blocks.items, out) |b, *c| c.* = switch (b) {
            .text => |t| .{ .text = t.items },
            .thinking => |t| .{ .thinking = .{ .text = t.text.items, .signature = t.signature } },
            .tool_call => |t| .{ .tool_call = .{ .id = t.id, .name = t.name, .arguments = t.arguments.items } },
        };
        return out;
    }
};

test "deltas merge into blocks in arrival order" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var bus: Bus = .init(gpa, std.testing.io);
    defer bus.deinit();

    var a: Assembler = .{ .arena = arena_state.allocator(), .bus = &bus, .session_id = "s", .location = "/", .message_id = "m" };
    const s = a.sink();
    try s.emit(.{ .thinking_delta = "let me " });
    try s.emit(.{ .thinking_delta = "think" });
    try s.emit(.{ .text_delta = "Hel" });
    try s.emit(.{ .text_delta = "lo" });
    try s.emit(.{ .tool_call_start = .{ .index = 0, .id = "c1", .name = "read" } });
    try s.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"pa" } });
    try s.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "th\":1}" } });
    try s.emit(.{ .done = .tool_use });

    const c = try a.content();
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expectEqualStrings("let me think", c[0].thinking.text);
    try std.testing.expectEqualStrings("Hello", c[1].text);
    try std.testing.expectEqualStrings("{\"path\":1}", c[2].tool_call.arguments);
    try std.testing.expectEqual(proto.message.StopReason.tool_use, a.stop.?);
}

test "a signature closes its reasoning block or stands alone" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var bus: Bus = .init(gpa, std.testing.io);
    defer bus.deinit();

    var a: Assembler = .{ .arena = arena_state.allocator(), .bus = &bus, .session_id = "s", .location = "/", .message_id = "m" };
    const s = a.sink();
    try s.emit(.{ .thinking_delta = "first" });
    try s.emit(.{ .thinking_signature = "one" });
    try s.emit(.{ .thinking_delta = "second" });
    try s.emit(.{ .text_delta = "hi" });
    try s.emit(.{ .thinking_signature = "two" });

    const c = try a.content();
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqualStrings("first", c[0].thinking.text);
    try std.testing.expectEqualStrings("one", c[0].thinking.signature.?);
    try std.testing.expectEqualStrings("second", c[1].thinking.text);
    try std.testing.expect(c[1].thinking.signature == null);
    try std.testing.expectEqualStrings("", c[3].thinking.text);
    try std.testing.expectEqualStrings("two", c[3].thinking.signature.?);
    try std.testing.expect(a.streamed());
}

test "tool call identity may arrive after its arguments" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var bus: Bus = .init(gpa, std.testing.io);
    defer bus.deinit();

    var a: Assembler = .{ .arena = arena_state.allocator(), .bus = &bus, .session_id = "s", .location = "/", .message_id = "m" };
    const s = a.sink();
    try s.emit(.{ .tool_call_delta = .{ .index = 1, .arguments = "{\"a\"" } });
    try s.emit(.{ .tool_call_start = .{ .index = 1, .id = "late", .name = "" } });
    try s.emit(.{ .tool_call_delta = .{ .index = 1, .arguments = ":1}" } });
    try s.emit(.{ .tool_call_start = .{ .index = 1, .id = "other", .name = "read" } });

    const c = try a.content();
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("late", c[0].tool_call.id);
    try std.testing.expectEqualStrings("read", c[0].tool_call.name);
    try std.testing.expectEqualStrings("{\"a\":1}", c[0].tool_call.arguments);
}
