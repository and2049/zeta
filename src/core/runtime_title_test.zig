const std = @import("std");
const Io = std.Io;
const Runtime = @import("Runtime.zig");
const Bus = @import("bus.zig").Bus;
const proto = @import("proto");
const plugin = @import("plugin");

test "title worker uses small model without tools, manual rename wins, delete joins" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.jsonc", .data = "{\"model\":\"fake/large\",\"small_model\":\"fake/tiny\"}" });
    const Fake = struct {
        entered: Io.Event = .unset,
        release: Io.Event = .unset,
        blocked: Io.Event = .unset,
        calls: usize = 0,
        fn stream(ctx: ?*anyopaque, _: std.mem.Allocator, provider_io: Io, _: plugin.provider.Options, request: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            try std.testing.expectEqualStrings("tiny", request.model);
            try std.testing.expect(std.mem.startsWith(u8, request.system, "Generate a short session title"));
            try std.testing.expectEqual(@as(usize, 0), request.tools.len);
            try std.testing.expectEqual(@as(usize, 1), request.messages.len);
            try std.testing.expectEqualStrings("first request", request.messages[0].content[0].text);
            if (self.calls == 1) {
                self.entered.set(provider_io);
                try self.release.wait(provider_io);
            } else if (self.calls == 3) {
                self.blocked.set(provider_io);
                try self.release.wait(provider_io); // cancelled by delete
            }
            try sink.emit(.{ .text_delta = "Generated heading\nignored" });
            try sink.emit(.{ .done = .stop });
        }
    };
    var fake: Fake = .{};
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    try @import("test_provider.zig").register(&registry);
    try registry.addApi(try registry.addPlugin(.{ .id = "test-api" }), .{ .id = @import("test_provider.zig").api_id, .ctx = &fake, .stream = Fake.stream });
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer rt.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const renamed = try rt.createSession(base);
    const renamed_id = try a.dupe(u8, renamed.id);
    try rt.sessions.get(renamed_id).?.session.append(.{ .id = "msg_first", .role = .user, .content = &.{.{ .text = "first request" }}, .timestamp = 1 });
    try rt.requestTitle(renamed_id);
    try fake.entered.wait(io);
    try std.testing.expectError(error.SessionBusy, rt.requestTitle(renamed_id));
    _ = try rt.updateSession(a, renamed_id, .{ .title = "Manual name" });
    fake.release.set(io);
    rt.sessions.get(renamed_id).?.title_worker.await(io) catch {};
    try std.testing.expectEqualStrings("Manual name", (try rt.snapshot(a, renamed_id)).info.title.?);

    const generated = try rt.createSession(base);
    const generated_id = try a.dupe(u8, generated.id);
    try rt.sessions.get(generated_id).?.session.append(.{ .id = "msg_second", .role = .user, .content = &.{.{ .text = "first request" }}, .timestamp = 1 });
    try rt.requestTitle(generated_id);
    rt.sessions.get(generated_id).?.title_worker.await(io) catch {};
    try std.testing.expectEqualStrings("Generated heading", (try rt.snapshot(a, generated_id)).info.title.?);
    var updated = false;
    while (try sub.next(io)) |frame| {
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(a, frame.bytes);
        if (std.mem.eql(u8, event.type, proto.event.types.session_updated) and std.mem.eql(u8, event.session.?, generated_id)) {
            updated = true;
            break;
        }
    }
    try std.testing.expect(updated);

    // A new blocked title call cannot retain the session after deletion.
    fake.release = .unset;
    const deleting = try rt.createSession(base);
    const deleting_id = try a.dupe(u8, deleting.id);
    try rt.sessions.get(deleting_id).?.session.append(.{ .id = "msg_third", .role = .user, .content = &.{.{ .text = "first request" }}, .timestamp = 1 });
    try rt.requestTitle(deleting_id);
    try fake.blocked.wait(io);
    try rt.deleteSession(deleting_id);
    try std.testing.expectError(error.SessionNotFound, rt.snapshot(a, deleting_id));
}
