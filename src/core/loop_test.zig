const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bus = @import("bus.zig").Bus;
const Session = @import("session.zig").Session;
const Inbox = @import("inbox.zig").Inbox;
const Loop = @import("loop.zig").Loop;
const types = proto.event.types;

const Fake = struct {
    script: []const []const plugin.provider.Event,
    calls: usize = 0,
    seen_messages: [4]usize = @splat(0),

    fn stream(ctx: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, req: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        defer f.calls += 1;
        f.seen_messages[f.calls] = req.messages.len;
        if (f.calls >= f.script.len) return error.ScriptExhausted;
        for (f.script[f.calls]) |ev| try sink.emit(ev);
    }
};

const Injected = struct {
    inbox: *Inbox,
    calls: usize = 0,

    fn stream(ctx: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, req: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
        const f: *Injected = @ptrCast(@alignCast(ctx.?));
        defer f.calls += 1;
        switch (f.calls) {
            0 => {
                try std.testing.expectEqual(@as(usize, 1), req.messages.len);
                try std.testing.expectEqualStrings("initial steer", req.messages[0].content[0].text);
                try f.inbox.push("msg_steer", "next step steer", .steer);
                try f.inbox.push("msg_queue", "later queued input", .queue);
                try sink.emit(.{ .tool_call_start = .{ .index = 0, .id = "call_1", .name = "read" } });
                try sink.emit(.{ .done = .tool_use });
            },
            1 => {
                try std.testing.expectEqual(@as(usize, 4), req.messages.len);
                try std.testing.expectEqualStrings("next step steer", req.messages[3].content[0].text);
                try sink.emit(.{ .text_delta = "after steer" });
                try sink.emit(.{ .done = .stop });
            },
            2 => {
                try std.testing.expectEqual(@as(usize, 6), req.messages.len);
                try std.testing.expectEqualStrings("initial queue", req.messages[5].content[0].text);
                try sink.emit(.{ .text_delta = "after first follow-up" });
                try sink.emit(.{ .done = .stop });
            },
            3 => {
                try std.testing.expectEqual(@as(usize, 8), req.messages.len);
                try std.testing.expectEqualStrings("later queued input", req.messages[7].content[0].text);
                try sink.emit(.{ .text_delta = "after second follow-up" });
                try sink.emit(.{ .done = .stop });
            },
            else => return error.UnexpectedTurn,
        }
    }
};

test "steering and each queued follow-up get their own turn and survive arena resets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_pending", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_initial_steer", "initial steer", .steer);
    try inbox.push("msg_initial_queue", "initial queue", .queue);

    var injected: Injected = .{ .inbox = &inbox };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "injected", .ctx = &injected, .stream = Injected.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "" },
    };
    try loop.run();

    try std.testing.expectEqual(@as(usize, 4), injected.calls);
    try std.testing.expect(inbox.isEmpty());
    const msgs = session.messages.items;
    try std.testing.expectEqual(@as(usize, 9), msgs.len);
    const user_indices = [_]usize{ 0, 3, 5, 7 };
    const user_ids = [_][]const u8{ "msg_initial_steer", "msg_steer", "msg_initial_queue", "msg_queue" };
    const user_texts = [_][]const u8{ "initial steer", "next step steer", "initial queue", "later queued input" };
    for (user_indices, user_ids, user_texts) |index, id, text| {
        try std.testing.expectEqual(proto.message.Role.user, msgs[index].role);
        try std.testing.expectEqualStrings(id, msgs[index].id);
        try std.testing.expectEqualStrings(text, msgs[index].content[0].text);
    }
    try std.testing.expectEqual(proto.message.Role.tool_result, msgs[2].role);
    try std.testing.expectEqualStrings("after steer", msgs[4].content[0].text);
    try std.testing.expectEqualStrings("after first follow-up", msgs[6].content[0].text);
    try std.testing.expectEqualStrings("after second follow-up", msgs[8].content[0].text);
}

test "an empty inbox makes no model request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_empty", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    var fake: Fake = .{ .script = &.{} };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "fake", .ctx = &fake, .stream = Fake.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "" },
    };
    try loop.run();
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
}

test "a text-only model sees a placeholder for earlier images; the log keeps them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_images", "/p");
    defer session.destroy(gpa, io);
    try session.append(.{ .id = "msg_image", .role = .user, .timestamp = 1, .content = &.{
        .{ .text = "look" },
        .{ .image = .{ .mimeType = "image/png", .data = "YWJj" } },
    } });
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_text", "and now?", .queue);
    const Check = struct {
        fn stream(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, req: plugin.provider.Request, sink: plugin.provider.Sink) !void {
            try std.testing.expectEqual(@as(usize, 2), req.messages.len);
            const parts = req.messages[0].content;
            try std.testing.expectEqualStrings("look", parts[0].text);
            try std.testing.expectEqualStrings(@import("projection.zig").image_placeholder, parts[1].text);
            try sink.emit(.{ .text_delta = "ok" });
            try sink.emit(.{ .done = .stop });
        }
    };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "check", .stream = Check.stream }, .options = .{ .accepts_images = false }, .provider_id = "p", .model_id = "m", .system = "" },
    };
    try loop.run();
    const msgs = session.messages.items;
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqual(proto.message.StopReason.stop, msgs[2].stopReason.?);
    try std.testing.expectEqualStrings("YWJj", msgs[0].content[1].image.data);
}

test "tool call turn then text turn, events in pi order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_t", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_u", "hi", .queue);

    var fake: Fake = .{ .script = &.{
        &.{ .{ .tool_call_start = .{ .index = 0, .id = "c1", .name = "read" } }, .{ .done = .tool_use } },
        &.{ .{ .text_delta = "done" }, .{ .usage = .{ .input = 5, .output = 1 } }, .{ .done = .stop } },
    } };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{
            .api = .{ .id = "fake", .ctx = &fake, .stream = Fake.stream },
            .options = .{},
            .provider_id = "p",
            .model_id = "m",
            .system = "sys",
        },
    };
    try loop.run();

    const msgs = session.messages.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    for (msgs) |msg| {
        if (msg.role == .assistant) {
            try std.testing.expect(msg.completedAt.? >= msg.timestamp);
        } else try std.testing.expect(msg.completedAt == null);
    }
    try std.testing.expectEqual(proto.message.Role.tool_result, msgs[2].role);
    try std.testing.expectEqualStrings("c1", msgs[2].toolCallId.?);
    try std.testing.expectEqualStrings("done", msgs[3].content[0].text);
    try std.testing.expectEqual(@as(u64, 5), msgs[3].usage.?.input);
    try std.testing.expectEqual(@as(usize, 1), fake.seen_messages[0]);
    try std.testing.expectEqual(@as(usize, 3), fake.seen_messages[1]);

    const expected = [_][]const u8{
        types.agent_start,        types.turn_start,         types.session_inbox_updated, types.message_start,        types.message_end,
        types.message_start,      types.message_part_delta, types.message_end,           types.tool_execution_start, types.tool_execution_end,
        types.message_start,      types.message_end,        types.turn_end,              types.turn_start,           types.message_start,
        types.message_part_delta, types.message_end,        types.turn_end,              types.agent_end,
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (expected) |want| {
        const f = (try sub.next(io)).?;
        defer f.release(gpa);
        const d = try proto.event.Decoded.parse(arena.allocator(), f.bytes);
        try std.testing.expectEqualStrings(want, d.type);
    }
    bus.unsubscribe(sub);
}

test "tool calls cut off by the length limit are failed and sent back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_l", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_u", "hi", .queue);

    var fake: Fake = .{ .script = &.{
        &.{ .{ .tool_call_start = .{ .index = 0, .id = "c1", .name = "write" } }, .{ .done = .length } },
        &.{ .{ .text_delta = "retrying" }, .{ .done = .stop } },
    } };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "fake", .ctx = &fake, .stream = Fake.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "" },
    };
    try loop.run();
    const msgs = session.messages.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expect(std.mem.indexOf(u8, msgs[2].content[0].text, "truncated") != null);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "denied tool is logged before ending the turn without another model step" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_denied", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_user", "try", .queue);
    const Gate = struct {
        fn deny(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: plugin.tool.Tool, _: *std.json.Value, _: proto.message.ToolCall) anyerror!@import("tools.zig").Verdict {
            return .deny;
        }
        fn tool(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
            return error.ToolMustNotRun;
        }
    };
    var fake: Fake = .{ .script = &.{&.{ .{ .tool_call_start = .{ .index = 0, .id = "call_denied", .name = "restricted" } }, .{ .done = .tool_use } }} };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{
            .api = .{ .id = "fake", .ctx = &fake, .stream = Fake.stream },
            .options = .{},
            .provider_id = "p",
            .model_id = "m",
            .system = "",
            .executable_tools = &.{.{ .name = "restricted", .description = "", .input_schema = "{}", .execute = Gate.tool }},
            .approval = .{ .ctx = null, .check = Gate.deny },
        },
    };
    try loop.run();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
    const result = session.messages.items[2];
    try std.testing.expect(result.isError);
    try std.testing.expectEqualStrings("call_denied", result.toolCallId.?);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text, "denied") != null);
}

test "provider error ends the run with an error message" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_e", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_u", "hi", .queue);

    var fake: Fake = .{ .script = &.{} };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{ .api = .{ .id = "fake", .ctx = &fake, .stream = Fake.stream }, .options = .{}, .provider_id = "p", .model_id = "m", .system = "" },
    };
    try loop.run();
    const last = session.messages.items[session.messages.items.len - 1];
    try std.testing.expectEqual(proto.message.StopReason.@"error", last.stopReason.?);
    try std.testing.expectEqualStrings("ScriptExhausted", last.errorMessage.?);
}

test {
    _ = @import("loop_failure_test.zig");
}
