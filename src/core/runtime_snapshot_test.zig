//! Runtime snapshot integration tests: in-flight drafts, inbox leases and pending permissions.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bus = @import("bus.zig").Bus;
const plugin = @import("plugin");
const proto = @import("proto");
const types = proto.event.types;
const default_api = @import("test_provider.zig").api_id;
const permissions = @import("permissions.zig");

test "snapshot projects assistant prefix through revision before later deltas" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.jsonc", .data = "{\"model\":\"fake/model\"}" });
    const Fake = struct {
        prefix: Io.Event = .unset,
        finish: Io.Event = .unset,
        fn stream(ctx: ?*anyopaque, _: Allocator, io_: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            try sink.emit(.{ .text_delta = "pre" });
            self.prefix.set(io_);
            try self.finish.wait(io_);
            try sink.emit(.{ .text_delta = "fix" });
            try sink.emit(.{ .done = .stop });
        }
    };
    var fake: Fake = .{};
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    try @import("test_provider.zig").register(&registry);
    try registry.addApi(try registry.addPlugin(.{ .id = "test-api" }), .{ .id = default_api, .ctx = &fake, .stream = Fake.stream });
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer rt.deinit();
    const info = try rt.createSession(base);
    _ = try rt.prompt(info.id, "go", .queue);
    try fake.prefix.wait(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const state = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expectEqualStrings("pre", state.inflight.?.content[0].text);
    try std.testing.expect(state.inflight.?.completedAt == null);
    const revision = state.revision;
    fake.finish.set(io);
    var found_later_delta = false;
    while (try sub.next(io)) |frame| {
        defer frame.release(gpa);
        if (frame.seq <= revision) continue;
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, types.message_part_delta)) {
            try std.testing.expectEqualStrings("fix", event.data.object.get("delta").?.string);
            found_later_delta = true;
        }
        if (std.mem.eql(u8, event.type, types.agent_end)) break;
    }
    try std.testing.expect(found_later_delta);
    const after = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expect(after.inflight == null);
    try std.testing.expectEqualStrings("prefix", after.messages[1].content[0].text);
    try std.testing.expect(after.messages[1].completedAt.? >= after.messages[1].timestamp);
}

test "leased input remains in snapshot until durable message promotion" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    try @import("test_provider.zig").register(&registry);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer rt.deinit();
    const info = try rt.createSession(base);
    const entry = rt.sessions.get(info.id).?;
    try entry.inbox.push("msg_pending", "retained", .queue);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try entry.inbox.takeNext(arena.allocator(), .queue);
    const waiting = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expectEqual(@as(usize, 1), waiting.inbox.len);
    try std.testing.expectEqual(@as(usize, 0), waiting.messages.len);
    const user: proto.Message = .{ .id = "msg_pending", .role = .user, .content = &.{.{ .text = "retained" }}, .timestamp = 1 };
    {
        rt.mutex.lockUncancelable(io);
        defer rt.mutex.unlock(io);
        try entry.session.append(user);
        entry.inbox.ack(user.id);
        try bus.publishValue(types.message_end, info.id, base, .{ .message = user });
    }
    const promoted = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expectEqual(@as(usize, 0), promoted.inbox.len);
    try std.testing.expectEqualStrings("retained", promoted.messages[0].content[0].text);
    try std.testing.expect(promoted.revision > waiting.revision);
}

test "snapshot includes pending permission and exposes a stable bus revision" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    try @import("test_provider.zig").register(&registry);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer rt.deinit();
    const info = try rt.createSession(base);
    rt.broker = permissions.Broker.init(gpa, io, &bus, &rt.ids);
    rt.broker.?.state_mutex = &rt.mutex;
    const Task = struct {
        broker: *permissions.Broker,
        request: permissions.Request,
        fn run(t: *@This()) Io.Cancelable!void {
            const ask = [_]permissions.Rule{.{ .action = "bash", .pattern = "*", .effect = .ask }};
            _ = t.broker.evaluate(t.request, &.{}, &ask, &.{}, 120_000) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                return;
            };
        }
    };
    var task: Task = .{ .broker = &rt.broker.?, .request = .{ .session = info.id, .location = base, .action = "bash", .pattern = "echo hi" } };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Task.run, .{&task});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var asked_id: ?[]const u8 = null;
    while (try sub.next(io)) |frame| {
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, "permission.asked")) {
            asked_id = event.data.object.get("id").?.string;
            break;
        }
    }
    const state = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expectEqual(@as(usize, 1), state.pendingPermissions.len);
    try std.testing.expectEqualStrings(asked_id.?, state.pendingPermissions[0].id);
    try std.testing.expect(state.revision >= 2); // create and ask
    try std.testing.expect(rt.replyPermission(asked_id.?, .deny));
    try group.await(io);
    var saw_resolved = false;
    while (try sub.next(io)) |frame| {
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, "permission.resolved")) {
            try std.testing.expect(event.seq > state.revision);
            try std.testing.expectEqualStrings(asked_id.?, event.data.object.get("id").?.string);
            saw_resolved = true;
            break;
        }
    }
    try std.testing.expect(saw_resolved);
    const after = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expectEqual(@as(usize, 0), after.pendingPermissions.len);
    try std.testing.expect(after.revision >= state.revision);
}
