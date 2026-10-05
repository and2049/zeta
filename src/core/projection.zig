//! Adapts the session history to the model a request goes to. The session
//! itself is never changed; changed messages are copied into `arena`.

const std = @import("std");
const proto = @import("proto");
const Allocator = std.mem.Allocator;
const Message = proto.Message;
const Content = proto.message.Content;
const shell = @import("shell.zig");

/// A text-only model sees a visible error in place of each image, so older
/// image turns never break the session. The log keeps the images; new image
/// prompts are refused at admission.
pub const image_placeholder = "ERROR: Cannot read image (this model does not support image input). Inform the user.";

pub const Target = struct {
    provider: []const u8,
    model: []const u8,
    accepts_images: bool,
};

/// Leaves out failed attempts, replaces images when the model cannot read
/// them, and drops reasoning signatures that another provider or model
/// produced. Returns `messages` unchanged when nothing needs adapting.
pub fn forModel(arena: Allocator, log: []const Message, target: Target) ![]const Message {
    // After a compaction the model sees its summary and what it kept.
    const messages = try @import("compaction.zig").visible(arena, log);
    for (messages, 0..) |m, i| {
        if (adapts(m, target) or failedAttempt(messages, i)) break;
    } else return messages;
    var kept: std.ArrayList(Message) = .empty;
    for (messages, 0..) |m, i| if (!failedAttempt(messages, i)) try kept.append(arena, m);
    const out = kept.items;
    for (out) |*m| {
        if (shell.is(m.*)) {
            m.content = try arena.dupe(Content, &.{.{ .text = try shell.modelText(arena, m.*) }});
            continue;
        }
        if (!adapts(m.*, target)) continue;
        const content = try arena.dupe(Content, m.content);
        const foreign = !sameModel(m.*, target);
        for (content) |*part| switch (part.*) {
            .image => if (!target.accepts_images) {
                part.* = .{ .text = image_placeholder };
            },
            .thinking => |*t| if (foreign) {
                t.signature = null;
            },
            else => {},
        };
        m.content = content;
    }
    return out;
}

/// A reply that failed after part of it streamed and was then retried: an
/// errored assistant message directly followed by another assistant message.
/// It stays in the log but the model never sees it.
pub fn failedAttempt(messages: []const Message, index: usize) bool {
    const m = messages[index];
    if (m.role != .assistant or m.stopReason != .@"error") return false;
    return index + 1 < messages.len and messages[index + 1].role == .assistant;
}

fn adapts(m: Message, target: Target) bool {
    if (shell.is(m)) return true;
    for (m.content) |part| switch (part) {
        .image => if (!target.accepts_images) return true,
        .thinking => |t| if (t.signature != null and !sameModel(m, target)) return true,
        else => {},
    };
    return false;
}

fn sameModel(m: Message, target: Target) bool {
    const provider = m.provider orelse return false;
    const model = m.model orelse return false;
    return std.mem.eql(u8, provider, target.provider) and std.mem.eql(u8, model, target.model);
}

test "unchanged history is returned as is" {
    const messages: []const Message = &.{
        .{ .id = "a", .role = .assistant, .timestamp = 0, .provider = "p", .model = "m", .content = &.{.{ .thinking = .{ .text = "t", .signature = "s" } }} },
    };
    const out = try forModel(std.testing.allocator, messages, .{ .provider = "p", .model = "m", .accepts_images = true });
    try std.testing.expectEqual(messages.ptr, out.ptr);
}

test "signatures from another model and unreadable images are dropped" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const image = try proto.message.Image.init(state.allocator(), "image/png", "YWJj");
    const messages: []const Message = &.{
        .{ .id = "u", .role = .user, .timestamp = 0, .content = &.{ .{ .text = "look" }, .{ .image = image } } },
        .{ .id = "a", .role = .assistant, .timestamp = 0, .provider = "p", .model = "old", .content = &.{.{ .thinking = .{ .text = "t", .signature = "s" } }} },
        .{ .id = "b", .role = .assistant, .timestamp = 0, .provider = "p", .model = "m", .content = &.{.{ .thinking = .{ .text = "t", .signature = "keep" } }} },
    };
    const out = try forModel(state.allocator(), messages, .{ .provider = "p", .model = "m", .accepts_images = false });
    try std.testing.expectEqualStrings(image_placeholder, out[0].content[1].text);
    try std.testing.expectEqualStrings("t", out[1].content[0].thinking.text);
    try std.testing.expect(out[1].content[0].thinking.signature == null);
    try std.testing.expectEqualStrings("keep", out[2].content[0].thinking.signature.?);
    try std.testing.expectEqualStrings("s", messages[1].content[0].thinking.signature.?);
}

test "a command the user ran reaches the model as one explained text" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const messages: []const Message = &.{
        .{ .id = "s", .role = .user, .timestamp = 0, .origin = shell.origin, .content = &.{ .{ .text = "git status" }, .{ .text = "clean" } } },
    };
    const out = try forModel(state.allocator(), messages, .{ .provider = "p", .model = "m", .accepts_images = true });
    try std.testing.expectEqual(@as(usize, 1), out[0].content.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0].content[0].text, "Command:\ngit status\n\nOutput:\nclean") != null);
    try std.testing.expectEqual(@as(usize, 2), messages[0].content.len);
}

test "a failed attempt that was retried is left out" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const messages: []const Message = &.{
        .{ .id = "u", .role = .user, .timestamp = 0, .content = &.{.{ .text = "hi" }} },
        .{ .id = "a", .role = .assistant, .timestamp = 0, .stopReason = .@"error", .content = &.{.{ .text = "part" }} },
        .{ .id = "b", .role = .assistant, .timestamp = 0, .stopReason = .stop, .content = &.{.{ .text = "whole" }} },
        .{ .id = "c", .role = .assistant, .timestamp = 0, .stopReason = .@"error", .content = &.{.{ .text = "last" }} },
    };
    const out = try forModel(state.allocator(), messages, .{ .provider = "p", .model = "m", .accepts_images = true });
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("b", out[1].id);
    // A final error that was not retried is still sent.
    try std.testing.expectEqualStrings("c", out[2].id);
}
