//! Every interception point, exercised through a real loop run.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bus = @import("bus.zig").Bus;
const Session = @import("session.zig").Session;
const Inbox = @import("inbox.zig").Inbox;
const Loop = @import("loop.zig").Loop;
const hook = plugin.hook;

const Provider = struct {
    calls: usize = 0,
    systems_hooked: bool = true,
    /// History length of each request.
    seen: [4]usize = @splat(0),

    fn stream(ctx: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, req: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
        const p: *Provider = @ptrCast(@alignCast(ctx.?));
        defer p.calls += 1;
        p.seen[p.calls] = req.messages.len;
        if (!std.mem.eql(u8, req.system, "hooked system")) p.systems_hooked = false;
        switch (p.calls) {
            0 => {
                try sink.emit(.{ .tool_call_start = .{ .index = 0, .id = "a", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .index = 0, .arguments = "{\"n\":1}" } });
                try sink.emit(.{ .tool_call_start = .{ .index = 1, .id = "b", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .index = 1, .arguments = "{\"n\":2}" } });
                try sink.emit(.{ .done = .tool_use });
            },
            1 => {
                try sink.emit(.{ .text_delta = "done" });
                try sink.emit(.{ .done = .stop });
            },
            2 => {
                try sink.emit(.{ .text_delta = "checked" });
                try sink.emit(.{ .done = .stop });
            },
            else => return error.UnexpectedRequest,
        }
    }
};

const Consumer = struct {
    fn pre(_: ?*anyopaque, arena: Allocator, _: Io, _: hook.Scope, call: hook.Call) anyerror!hook.ToolPre {
        const n = call.args.object.get("n").?.integer;
        if (n == 2) return .{ .block = "two is not allowed" };
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "n", .{ .integer = n * 10 });
        return .{ .rewrite = .{ .object = args } };
    }
    fn post(_: ?*anyopaque, arena: Allocator, _: Io, _: hook.Scope, _: hook.Call, result: plugin.tool.Result) anyerror!hook.ToolPost {
        return .{ .replace = .{ .text = try std.fmt.allocPrint(arena, "{s}!", .{result.text}) } };
    }
    fn request(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, req: plugin.provider.Request) anyerror!hook.ProviderRequest {
        var out = req;
        out.system = "hooked system";
        return .{ .replace = out };
    }
    fn context(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, messages: []const proto.Message) anyerror!hook.ContextBuild {
        return .{ .replace = messages[messages.len - 1 ..] };
    }
    fn stop(_: ?*anyopaque, _: Allocator, _: Io, scope: hook.Scope, s: hook.Stop) anyerror!hook.TurnStop {
        std.debug.assert(std.mem.eql(u8, scope.model, "m"));
        return if (s.continued) .stop else .{ .@"continue" = "check again" };
    }
    fn echo(_: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
        return .{ .text = try std.fmt.allocPrint(arena, "n={d}", .{args.object.get("n").?.integer}) };
    }
};

test "hooks rewrite and block calls, replace results, context and request, and continue a stop once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_hooks", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_first", "go", .queue);
    var provider: Provider = .{};
    const echo: plugin.tool.Tool = .{
        .name = "echo",
        .description = "",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"}},\"required\":[\"n\"]}",
        .execute = Consumer.echo,
    };
    const chain: []const plugin.Registry.Resolved(hook.Hook) = &.{
        .{ .plugin = "t", .value = .{ .point = .{ .tool_pre = Consumer.pre } } },
        .{ .plugin = "t", .value = .{ .point = .{ .tool_post = Consumer.post } } },
        .{ .plugin = "t", .value = .{ .point = .{ .provider_request = Consumer.request } } },
        .{ .plugin = "t", .value = .{ .point = .{ .context_build = Consumer.context } } },
        .{ .plugin = "t", .value = .{ .point = .{ .turn_stop = Consumer.stop } } },
    };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{
            .api = .{ .id = "fake", .ctx = &provider, .stream = Provider.stream },
            .options = .{},
            .provider_id = "p",
            .model_id = "m",
            .system = "plain system",
            .tools = &.{echo.declaration()},
            .executable_tools = &.{echo},
            .hooks = chain,
        },
    };
    try loop.run();

    try std.testing.expectEqual(@as(usize, 3), provider.calls);
    try std.testing.expect(provider.systems_hooked);
    // context.build left only the newest message in every request.
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, provider.seen[0..3]);
    const msgs = session.messages.items;
    const texts = [_][]const u8{ "go", "", "n=10!", "two is not allowed", "done", "check again", "checked" };
    try std.testing.expectEqual(texts.len, msgs.len);
    for (texts, msgs) |text, m| if (text.len > 0) try std.testing.expectEqualStrings(text, m.content[0].text);
    try std.testing.expect(msgs[3].isError);
    // The logged system entry is what the provider was sent.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const logged = session.system_hash.?;
    try std.testing.expectEqualStrings(logged, try session.recordSystem(scratch.allocator(), "hooked system", &.{echo.declaration()}, 0));
    try std.testing.expectEqualStrings(logged, msgs[6].systemHash.?);
}

const Reply = struct {
    fn stream(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
        try sink.emit(.{ .text_delta = "ok" });
        try sink.emit(.{ .done = .stop });
    }
};

const Gatekeeper = struct {
    fn start(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, source: hook.SessionSource) anyerror!?[]const u8 {
        return if (source == .startup) "branch: main" else null;
    }
    fn submit(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, prompt: hook.Prompt) anyerror!hook.PromptSubmit {
        if (std.mem.eql(u8, prompt.text, "secret")) return .{ .block = "no secrets" };
        return .{ .context = "remember the tests" };
    }
};

test "session_start adds context once; prompt_submit blocks a prompt or adds context after it" {
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
    const session = try Session.create(gpa, io, base, "ses_submit", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_secret", "secret", .queue);
    try inbox.push("msg_go", "go", .queue);
    const chain: []const plugin.Registry.Resolved(hook.Hook) = &.{
        .{ .plugin = "t", .value = .{ .point = .{ .session_start = Gatekeeper.start } } },
        .{ .plugin = "t", .value = .{ .point = .{ .prompt_submit = Gatekeeper.submit } } },
    };
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{
            .api = .{ .id = "fake", .stream = Reply.stream },
            .options = .{},
            .provider_id = "p",
            .model_id = "m",
            .system = "",
            .hooks = chain,
            .session_start = .startup,
        },
    };
    try loop.run();

    const msgs = session.messages.items;
    const texts = [_][]const u8{ "branch: main", "go", "remember the tests", "ok" };
    try std.testing.expectEqual(texts.len, msgs.len);
    for (texts, msgs) |text, m| try std.testing.expectEqualStrings(text, m.content[0].text);
    try std.testing.expectEqualStrings("hook", msgs[0].origin.?);
    try std.testing.expect(msgs[1].origin == null);
    try std.testing.expectEqualStrings("hook", msgs[2].origin.?);
    try std.testing.expect(inbox.isEmpty());

    var blocked = false;
    var frames: [1]*@import("bus.zig").Frame = undefined;
    while ((sub.queue.getUncancelable(io, &frames, 0) catch 0) == 1) {
        defer frames[0].release(gpa);
        const bytes = frames[0].bytes;
        if (std.mem.indexOf(u8, bytes, "\"prompt.blocked\"") != null) {
            blocked = std.mem.indexOf(u8, bytes, "no secrets") != null and std.mem.indexOf(u8, bytes, "msg_secret") != null;
        }
    }
    try std.testing.expect(blocked);
}

test "session_start runs before prompt hooks even when the only prompt is blocked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var ids: proto.id.Generator = .{};
    const session = try Session.create(gpa, io, base, "ses_blocked", "/p");
    defer session.destroy(gpa, io);
    var inbox: Inbox = .init(gpa, io);
    defer inbox.deinit();
    try inbox.push("msg_secret", "secret", .queue);
    var started = false;
    var loop: Loop = .{
        .gpa = gpa,
        .io = io,
        .bus = &bus,
        .ids = &ids,
        .session = session,
        .inbox = &inbox,
        .config = .{
            .api = .{ .id = "fake", .stream = Reply.stream },
            .options = .{},
            .provider_id = "p",
            .model_id = "m",
            .system = "",
            .hooks = &.{
                .{ .plugin = "t", .value = .{ .point = .{ .session_start = Gatekeeper.start } } },
                .{ .plugin = "t", .value = .{ .point = .{ .prompt_submit = Gatekeeper.submit } } },
            },
            .session_start = .startup,
            .session_started = &started,
        },
    };
    try loop.run();
    try std.testing.expect(started);
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqualStrings("branch: main", session.messages.items[0].content[0].text);
}
