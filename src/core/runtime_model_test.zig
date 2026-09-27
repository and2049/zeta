//! Default model integration tests: fallback, remembered picks, pinning.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bus = @import("bus.zig").Bus;
const plugin = @import("plugin");
const proto = @import("proto");
const config = @import("config.zig");
const runtime_model = @import("runtime_model.zig");

const Fake = struct {
    last: [32]u8 = undefined,
    len: usize = 0,

    fn stream(ctx: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Options, request: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.len = @min(request.model.len, self.last.len);
        @memcpy(self.last[0..self.len], request.model[0..self.len]);
        try sink.emit(.{ .text_delta = "ok" });
        try sink.emit(.{ .done = .stop });
    }

    fn model(self: *const Fake) []const u8 {
        return self.last[0..self.len];
    }

    fn resolve(_: ?*anyopaque, _: Allocator, _: Io, _: plugin.provider.Query) anyerror!plugin.provider.Route {
        return .{ .api = "fake-api", .options = .{} };
    }

    fn listing(_: ?*anyopaque, arena: Allocator, _: Io, _: plugin.provider.Query) anyerror![]const std.json.Value {
        return std.json.parseFromSliceLeaky([]const std.json.Value, arena,
            \\[{"id":"listed","models":[{"id":"first"},{"id":"second"}]}]
        , .{});
    }
};

fn runPrompt(rt: *Runtime, sub: anytype, id: []const u8, arena: Allocator) !void {
    _ = try rt.prompt(id, "hi", .queue);
    while (try sub.next(rt.io)) |frame| {
        defer frame.release(rt.gpa);
        const event = try proto.event.Decoded.parse(arena, frame.bytes);
        if (std.mem.eql(u8, event.type, proto.event.types.session_error)) return error.RunFailed;
        if (std.mem.eql(u8, event.type, proto.event.types.session_idle) and std.mem.eql(u8, event.session.?, id)) return;
    }
}

test "new sessions start on the remembered pick, else the first listed model, and keep what they ran with" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const state_dir = try std.fs.path.join(a, &.{ base, "state" });

    var fake: Fake = .{};
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    const owner = try registry.addPlugin(.{ .id = "listed" });
    try registry.addProvider(owner, .{ .id = "listed", .name = "Listed", .resolve = Fake.resolve, .models = Fake.listing });
    try registry.addApi(owner, .{ .id = "fake-api", .ctx = &fake, .stream = Fake.stream });
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base, .state_dir = state_dir });
    defer rt.deinit();

    // Nothing configured or remembered: the first listed model, pinned.
    const first = try a.dupe(u8, (try rt.createSession(base)).id);
    try runPrompt(&rt, sub, first, a);
    try std.testing.expectEqualStrings("first", fake.model());
    try std.testing.expectEqualStrings("listed/first", (try rt.snapshot(a, first)).options.model.?);
    try std.testing.expect(rt.sessions.get(first).?.session.model_selected);
    // A pin is not a pick.
    try std.testing.expect(runtime_model.read(a, io, state_dir).model == null);

    // A pick in another session is remembered for new ones.
    const picker = try a.dupe(u8, (try rt.createSession(base)).id);
    _ = try rt.updateSession(a, picker, .{ .model = "listed/second", .thinking = "high" });
    const remembered = runtime_model.read(a, io, state_dir);
    try std.testing.expectEqualStrings("listed/second", remembered.model.?);
    try std.testing.expectEqualStrings("high", remembered.thinking.?);

    // The pinned session keeps its model; a new one takes the pick.
    try runPrompt(&rt, sub, first, a);
    try std.testing.expectEqualStrings("first", fake.model());
    const fresh = try a.dupe(u8, (try rt.createSession(base)).id);
    try runPrompt(&rt, sub, fresh, a);
    try std.testing.expectEqualStrings("second", fake.model());
    try std.testing.expectEqualStrings("high", rt.sessions.get(fresh).?.session.metadata.thinking.?);

    // Config wins over the remembered pick; `auto` forgets the level.
    try tmp.dir.writeFile(io, .{ .sub_path = config.file_name, .data = "{\"model\":\"listed/configured\"}" });
    var cfg = try config.load(a, io, &env, base, base);
    try runtime_model.fill(&rt, a, base, &cfg);
    try std.testing.expectEqualStrings("listed/configured", cfg.model.?);
    try std.testing.expectEqual(config.Source.remembered, cfg.source("thinking").?);
    _ = try rt.updateSession(a, picker, .{ .thinking = "auto" });
    try std.testing.expect(runtime_model.read(a, io, state_dir).thinking == null);
    try std.testing.expectEqualStrings("listed/second", runtime_model.read(a, io, state_dir).model.?);
}
