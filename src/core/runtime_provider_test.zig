//! Authentication-selected transports must apply to ordinary coding runs.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const plugin = @import("plugin");
const proto = @import("proto");
const Io = std.Io;
const A = std.mem.Allocator;

test "resolved transport and request authentication reach the selected adapter" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const Fake = struct {
        called: std.atomic.Value(bool) = .init(false),
        fn resolve(ctx: ?*anyopaque, _: A, _: Io, q: plugin.provider.Query) !plugin.provider.Route {
            try std.testing.expectEqualStrings("openai", q.provider);
            return .{ .api = "oauth-test", .options = .{ .authentication = .{ .ctx = ctx, .resolve = credentials }, .account_id = "account" } };
        }
        fn credentials(_: ?*anyopaque, _: A, _: Io) !plugin.provider.Credentials {
            return .{ .apiKey = "refreshed", .account_id = "account" };
        }
        fn stream(ctx: ?*anyopaque, arena: A, io_: Io, opts: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const auth = opts.authentication orelse return error.MissingAuthentication;
            const value = try auth.resolve(auth.ctx, arena, io_);
            try std.testing.expectEqualStrings("refreshed", value.apiKey);
            try std.testing.expectEqualStrings("account", opts.account_id.?);
            self.called.store(true, .release);
            try sink.emit(.{ .text_delta = "authenticated" });
            try sink.emit(.{ .done = .stop });
        }
    };
    var fake: Fake = .{};
    var registry: plugin.Registry = .init(a, io);
    defer registry.deinit();
    // No default adapter is registered: ignoring the provider's route must fail.
    try registry.addApi(try registry.addPlugin(.{ .id = "test-api" }), .{ .id = "oauth-test", .ctx = &fake, .stream = Fake.stream });
    try registry.addProvider(try registry.addPlugin(.{ .id = "openai" }), .{ .id = "openai", .name = "OpenAI", .ctx = &fake, .resolve = Fake.resolve });
    var bus: @import("bus.zig").Bus = .init(a, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var rt = Runtime.init(a, io, &bus, &registry, &env, .{ .config_dir = dir, .sessions_dir = dir });
    defer rt.deinit();
    const info = try rt.createSessionWithOptions(dir, .{ .model = "openai/test" });
    _ = try rt.prompt(info.id, "go", .queue);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    while (try sub.next(io)) |frame| {
        defer frame.release(a);
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, proto.event.types.agent_end)) break;
    }
    try std.testing.expect(fake.called.load(.acquire));
    const snapshot = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expectEqualStrings("authenticated", snapshot.messages[1].content[0].text);
    fake.called.store(false, .release);
    try rt.requestTitle(info.id);
    try rt.sessions.get(info.id).?.title_worker.await(io);
    try std.testing.expect(fake.called.load(.acquire));
    try std.testing.expectEqualStrings("authenticated", (try rt.snapshot(arena.allocator(), info.id)).info.title.?);
}
