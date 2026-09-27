//! How inbox items become conversation: prompts pass the prompt.submit
//! hooks (a blocked one leaves the inbox), compaction requests run in turn,
//! and hook context is logged as marked user messages.
const std = @import("std");
const proto = @import("proto");
const Allocator = std.mem.Allocator;
const Loop = @import("loop.zig").Loop;
const Item = @import("inbox.zig").Item;
const types = proto.event.types;

/// A prompt on its way into the conversation, with any text hooks add after it.
pub const Pending = struct {
    item: Item,
    context: ?[]const u8 = null,
    /// Written by a hook rather than the user.
    from_hook: bool = false,
};

/// The next inbox item the prompt.submit hooks let through. A blocked
/// item is dropped from the inbox and reported as `prompt.blocked`.
pub fn take(l: *Loop, arena: Allocator, delivery: @import("inbox.zig").Delivery) !?Pending {
    while (try l.inbox.takeNext(arena, delivery)) |item| {
        if (item.kind == .compact) {
            _ = try @import("loop_compaction.zig").compactNow(l, .manual, item.text);
            settle(l, item.id);
            continue;
        }
        const submitted = try l.hooks().promptSubmit(arena, l.io, .{ .id = item.id, .text = item.text });
        const reason = submitted.blocked orelse return .{ .item = item, .context = submitted.context };
        settle(l, item.id);
        try l.emit(types.prompt_blocked, .{ .inboxId = item.id, .reason = reason });
    }
    return null;
}

/// Takes an item out of the inbox that will not become a message.
fn settle(l: *Loop, id: []const u8) void {
    if (l.state_mutex) |mutex| mutex.lockUncancelable(l.io);
    defer if (l.state_mutex) |mutex| mutex.unlock(l.io);
    l.inbox.ack(id);
    var scratch: std.heap.ArenaAllocator = .init(l.gpa);
    defer scratch.deinit();
    if (l.inbox.snapshot(scratch.allocator())) |items| {
        l.emit(types.session_inbox_updated, .{ .inbox = items }) catch {};
    } else |_| {}
}

pub fn appendUser(l: *Loop, arena: Allocator, next: Pending) !void {
    const item = next.item;
    const content = try arena.alloc(proto.message.Content, 1 + item.images.len);
    content[0] = .{ .text = item.text };
    for (item.images, content[1..]) |image, *part| part.* = .{ .image = image };
    try l.appendMessage(.{
        .id = item.id,
        .role = .user,
        .content = content,
        .timestamp = l.now(),
        .origin = if (next.from_hook) "hook" else null,
    });
    if (next.context) |text| try appendHookText(l, text);
}

/// Context a hook added: a user message the model sees, marked as the
/// hook's so clients can tell it from what the user typed.
pub fn appendHookText(l: *Loop, text: []const u8) !void {
    const buf = l.ids.next(l.io, .message);
    try l.appendMessage(.{
        .id = buf.slice(),
        .role = .user,
        .content = &.{.{ .text = text }},
        .timestamp = l.now(),
        .origin = "hook",
    });
}
