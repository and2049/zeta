//! Runtime lifecycle and recovery integration tests.
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

test "restore retains selectors, snapshot pages by exclusive cursor, abort and delete idle session" {
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
    const created = try rt.createSessionWithOptions("/project", .{ .profile = "dev", .model = "x/model", .environment = .{} });
    const id = try gpa.dupe(u8, created.id);
    defer gpa.free(id);
    const entry = rt.sessions.get(id).?;
    try entry.session.append(.{ .id = "msg_a", .role = .user, .content = &.{.{ .text = "one" }}, .timestamp = 1 });
    try entry.session.append(.{ .id = "msg_b", .role = .user, .content = &.{.{ .text = "two" }}, .timestamp = 2 });
    rt.deinit();
    var reopened: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer reopened.deinit();
    const report = try reopened.restore();
    try std.testing.expectEqual(@as(usize, 1), report.loaded);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const recent = try reopened.snapshotPage(a, id, null, 1);
    try std.testing.expectEqualStrings("msg_b", recent.messages[0].id);
    try std.testing.expectEqualStrings("msg_b", recent.nextBefore.?);
    try std.testing.expectEqualStrings("dev", recent.options.profile.?);
    try std.testing.expectEqualStrings("x/model", recent.options.model.?);
    try std.testing.expect(recent.options.environment != null);
    const older = try reopened.snapshotPage(a, id, recent.nextBefore, 1);
    try std.testing.expectEqualStrings("msg_a", older.messages[0].id);
    try std.testing.expect(older.nextBefore == null);
    const owned_context = try reopened.context(a, id);
    try reopened.abortSession(id);
    try std.testing.expect(!(try reopened.snapshot(a, id)).running);
    try reopened.deleteSession(id);
    try std.testing.expectEqualStrings("/project", owned_context.location);
    try std.testing.expectEqualStrings("x/model", owned_context.options.model.?);
    try std.testing.expectError(error.SessionNotFound, reopened.snapshot(a, id));
    try std.testing.expectEqual(@as(usize, 0), (try reopened.restore()).loaded);
    const bad_path = try std.fmt.allocPrint(a, "{s}/{s}/ses_corrupt.jsonl", .{ base, &@import("session.zig").locationHash("/project") });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_path, .data = "invalid json\n" });
    const bad = try reopened.restore();
    try std.testing.expectEqual(@as(usize, 1), bad.skipped);
    try std.testing.expectEqual(@as(usize, 0), bad.loaded);
}

test "session patch persists title and selected model, returns owned info" {
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
    const created = try rt.createSession(base);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try a.dupe(u8, created.id);
    try std.testing.expectError(error.InvalidPatch, rt.updateSession(a, id, .{ .model = "" }));
    try std.testing.expectError(error.InvalidPatch, rt.updateSession(a, id, .{ .model = "invalid" }));
    try std.testing.expectError(error.InvalidPatch, rt.updateSession(a, id, .{ .title = " \t" }));
    const patched = try rt.updateSession(a, id, .{ .model = "fake/new", .title = "New title" });
    try std.testing.expectEqualStrings("New title", patched.title.?);
    try std.testing.expectEqualStrings("fake/new", (try rt.snapshot(a, id)).options.model.?);
    try std.testing.expectEqual(@as(usize, 0), (try rt.listSessions(a, base, null)).len);
    const path = try @import("session_storage.zig").logPath(a, base, base, id);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
    try rt.sessions.get(id).?.session.append(.{ .id = "msg_first", .role = .user, .content = &.{}, .timestamp = 1 });
    try std.testing.expectEqual(@as(usize, 1), (try rt.listSessions(a, base, null)).len);
    _ = try Io.Dir.cwd().statFile(io, path, .{});
    rt.deinit();
    try std.testing.expectEqualStrings("New title", patched.title.?);
    var restored: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try restored.restore()).loaded);
    const snapshot = try restored.snapshot(a, id);
    try std.testing.expectEqualStrings("New title", snapshot.info.title.?);
    try std.testing.expectEqualStrings("fake/new", snapshot.options.model.?);
    try std.testing.expect(restored.sessions.get(id).?.session.model_selected);
}

test "unused session stays in memory and deletion needs no log" {
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
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer rt.deinit();
    const id = try gpa.dupe(u8, (try rt.createSession(base)).id);
    defer gpa.free(id);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings(id, (try rt.snapshot(arena.allocator(), id)).info.id);
    try std.testing.expectEqual(@as(usize, 0), (try rt.listSessions(arena.allocator(), base, null)).len);
    const path = try @import("session_storage.zig").logPath(arena.allocator(), base, base, id);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
    const fork = try rt.fork(arena.allocator(), id, null);
    try std.testing.expect(fork.forkedFrom == null);
    try std.testing.expectEqual(@as(usize, 0), (try rt.listSessions(arena.allocator(), base, null)).len);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, try @import("session_storage.zig").logPath(arena.allocator(), base, base, fork.id), .{}));
    try rt.deleteSession(fork.id);
    try rt.deleteSession(id);
    try std.testing.expectError(error.SessionNotFound, rt.snapshot(arena.allocator(), id));
}

test "active run keeps its admitted model while next run uses patch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.jsonc", .data = "{\"model\":\"fake/old\"}" });
    const Fake = struct {
        started: Io.Event = .unset,
        release: Io.Event = .unset,
        next: Io.Event = .unset,
        calls: usize = 0,
        fn stream(ctx: ?*anyopaque, _: Allocator, io_: Io, _: plugin.provider.Options, request: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                try std.testing.expectEqualStrings("old", request.model);
                self.started.set(io_);
                try self.release.wait(io_);
            } else {
                try std.testing.expectEqualStrings("new", request.model);
                self.next.set(io_);
            }
            try sink.emit(.{ .text_delta = "ok" });
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
    _ = try rt.prompt(info.id, "one", .queue);
    try fake.started.wait(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try rt.updateSession(arena.allocator(), info.id, .{ .model = "fake/new" });
    try std.testing.expectError(error.InboxItemNotFound, rt.removeInboxItem(info.id, "missing"));
    fake.release.set(io);
    while (try sub.next(io)) |frame| {
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(arena.allocator(), frame.bytes);
        if (std.mem.eql(u8, event.type, types.session_idle)) break;
    }
    _ = try rt.prompt(info.id, "two", .queue);
    try fake.next.wait(io);
    try rt.abort(info.id);
}

test "abort joins a blocked provider, discards queued prompts, and allows reuse" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.jsonc", .data = "{\"model\":\"fake/model\"}" });
    const Fake = struct {
        started: Io.Event = .unset,
        second: Io.Event = .unset,
        calls: usize = 0,
        fn stream(ctx: ?*anyopaque, _: Allocator, io_: Io, _: plugin.provider.Options, _: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                self.started.set(io_);
                try self.second.wait(io_); // canceled by abort, never signaled
            } else {
                try sink.emit(.{ .text_delta = "reused" });
                try sink.emit(.{ .done = .stop });
                self.second.set(io_);
            }
        }
    };
    var fake: Fake = .{};
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    try @import("test_provider.zig").register(&registry);
    try registry.addApi(try registry.addPlugin(.{ .id = "test-api" }), .{ .id = default_api, .ctx = &fake, .stream = Fake.stream });
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer rt.deinit();
    const info = try rt.createSession(base);
    _ = try rt.prompt(info.id, "first", .queue);
    try fake.started.wait(io);
    var hydrated_arena: std.heap.ArenaAllocator = .init(gpa);
    defer hydrated_arena.deinit();
    const hydrated = try rt.snapshot(hydrated_arena.allocator(), info.id);
    _ = try rt.prompt(info.id, "discard", .queue);
    rt.mutex.lockUncancelable(io);
    rt.sessions.get(info.id).?.stopping = true;
    rt.mutex.unlock(io);
    try std.testing.expectError(error.SessionBusy, rt.prompt(info.id, "racing prompt", .queue));
    try std.testing.expectError(error.SessionBusy, rt.deleteSession(info.id));
    rt.mutex.lockUncancelable(io);
    rt.sessions.get(info.id).?.stopping = false;
    rt.mutex.unlock(io);
    try rt.abort(info.id);
    try std.testing.expect(rt.sessions.get(info.id).?.inbox.isEmpty());
    var event_arena: std.heap.ArenaAllocator = .init(gpa);
    defer event_arena.deinit();
    const stopped = try rt.snapshot(event_arena.allocator(), info.id);
    var saw_admission = false;
    var saw_clearing = false;
    while (try sub.next(io)) |frame| {
        defer frame.release(gpa);
        const event = try proto.event.Decoded.parse(event_arena.allocator(), frame.bytes);
        if (!std.mem.eql(u8, event.type, types.session_inbox_updated)) continue;
        try std.testing.expect(frame.seq <= stopped.revision);
        const items = event.data.object.get("inbox").?.array.items;
        for (items) |item| {
            if (std.mem.eql(u8, item.object.get("text").?.string, "discard")) {
                try std.testing.expect(frame.seq > hydrated.revision);
                saw_admission = true;
            }
        }
        if (saw_admission and items.len == 0) {
            saw_clearing = true;
            break;
        }
    }
    try std.testing.expect(saw_admission and saw_clearing);
    _ = try rt.prompt(info.id, "second", .queue);
    try fake.second.wait(io);
    try rt.abort(info.id);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const state = try rt.snapshot(arena.allocator(), info.id);
    try std.testing.expect(!state.running);
    for (state.messages) |message| for (message.content) |part| {
        if (part == .text) try std.testing.expect(!std.mem.eql(u8, part.text, "discard"));
    };
}

test "restores metadata header larger than a reader buffer and owns create result" {
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
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const long_profile = try arena.allocator().alloc(u8, 70 * 1024);
    @memset(long_profile, 'a');
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    const info = try rt.createSessionWithOptionsOwned(arena.allocator(), base, .{ .profile = long_profile });
    try rt.sessions.get(info.id).?.session.append(.{ .id = "msg_first", .role = .user, .content = &.{}, .timestamp = 1 });
    rt.deinit();
    try std.testing.expectEqualStrings(base, info.location);
    var restored: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = base });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try restored.restore()).loaded);
    const state = try restored.snapshot(arena.allocator(), info.id);
    try std.testing.expectEqualStrings(long_profile, state.options.profile.?);
}

test "prompt runs a worker that uses the configured model and key" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    try tmp.dir.createDirPath(io, "cfg");
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/zeta.jsonc", .data =
        \\{ "model": "my-llm/big", "provider": { "my-llm": { "options": { "baseURL": "http://x", "apiKey": "key" } } } }
    });
    var paths_arena: std.heap.ArenaAllocator = .init(gpa);
    defer paths_arena.deinit();
    const cfg_dir = try std.fs.path.join(paths_arena.allocator(), &.{ base, "cfg" });
    const sess_dir = try std.fs.path.join(paths_arena.allocator(), &.{ base, "sessions" });
    const project = try std.fs.path.join(paths_arena.allocator(), &.{ base, "project" });

    const Fake = struct {
        var seen_key: [16]u8 = undefined;
        var seen_model: [16]u8 = undefined;
        var saw_tool = false;
        fn stream(_: ?*anyopaque, _: Allocator, _: Io, o: plugin.provider.Options, r: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
            @memcpy(seen_key[0..3], o.apiKey.?[0..3]);
            @memcpy(seen_model[0..3], r.model[0..3]);
            saw_tool = r.tools.len == 1 and std.mem.eql(u8, r.tools[0].name, "test_tool");
            try sink.emit(.{ .text_delta = "ok" });
            try sink.emit(.{ .done = .stop });
        }
        fn execute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
            return .{ .text = "ok" };
        }
    };
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    try @import("test_provider.zig").register(&registry);
    try registry.addApi(try registry.addPlugin(.{ .id = "test-api" }), .{ .id = default_api, .stream = Fake.stream });
    try registry.addTool(try registry.addPlugin(.{ .id = "test-tool" }), .{ .name = "test_tool", .description = "test", .input_schema = "{}", .execute = Fake.execute });

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    var bus: Bus = .init(gpa, io);
    defer bus.deinit();
    const sub = try bus.subscribe();
    defer bus.unsubscribe(sub);

    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = cfg_dir, .sessions_dir = sess_dir });
    defer rt.deinit();
    const info = try rt.createSessionWithOptions(project, .{ .model = "my-llm/alt" });
    _ = try rt.prompt(info.id, "hello", .queue);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    while (try sub.next(io)) |f| {
        defer f.release(gpa);
        const d = try proto.event.Decoded.parse(arena.allocator(), f.bytes);
        if (std.mem.eql(u8, d.type, types.agent_end)) break;
    }
    try std.testing.expectEqualStrings("key", Fake.seen_key[0..3]);
    try std.testing.expectEqualStrings("alt", Fake.seen_model[0..3]);
    try std.testing.expect(Fake.saw_tool);
}
