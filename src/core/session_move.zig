//! Move an idle session's durable log and saved outputs to a new project.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const proto = @import("proto");
const Io = std.Io;

pub const Result = struct { moved: bool, location: []const u8 };

/// Result strings belong to `arena`; session state remains runtime-owned.
pub fn move(rt: *Runtime, arena: std.mem.Allocator, id: []const u8, directory: []const u8) !Result {
    if (!std.fs.path.isAbsolute(directory)) return error.RelativeLocation;
    const dir = Io.Dir.cwd().openDir(rt.io, directory, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.DirectoryNotFound,
        error.NotDir => return error.NotDirectory,
        else => return err,
    };
    dir.close(rt.io);
    const location = try @import("location.zig").resolve(arena, rt.io, directory);
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(id) orelse return error.SessionNotFound;
    if (entry.running or entry.pending_options != null or entry.stopping) return error.SessionBusy;
    if (std.mem.eql(u8, entry.session.info.location, location)) return .{ .moved = false, .location = try arena.dupe(u8, location) };
    const persisted = entry.session.file != null;
    try entry.session.moveLocation(rt.sessions_dir, location);
    const info = entry.session.info;
    rt.bus.publishValue(proto.event.types.session_moved, info.id, info.location, .{ .location = info.location }) catch {};
    if (persisted) {
        const text = try std.fmt.allocPrint(arena, "The project directory is now {s}.", .{info.location});
        const message_id = rt.ids.next(rt.io, .message);
        const message: proto.Message = .{
            .id = message_id.slice(),
            .role = .user,
            .content = &.{.{ .text = text }},
            .timestamp = Io.Clock.real.now(rt.io).toMilliseconds(),
            .origin = "move",
        };
        try entry.session.append(message);
        try rt.bus.publishValue(proto.event.types.message_start, info.id, info.location, .{ .message = message });
        try rt.bus.publishValue(proto.event.types.message_end, info.id, info.location, .{ .message = message });
    }
    return .{ .moved = true, .location = try arena.dupe(u8, info.location) };
}

test "persisted and empty moves, no-op, admission, and interrupted rename recovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const project_a = try std.fmt.allocPrint(a, "{s}/a", .{base});
    const project_b = try std.fmt.allocPrint(a, "{s}/b", .{base});
    try tmp.dir.createDirPath(io, "a/.git");
    try tmp.dir.createDirPath(io, "b/.git");
    var bus: @import("bus.zig").Bus = .init(gpa, io);
    defer bus.deinit();
    var registry: @import("plugin").Registry = .init(gpa, io);
    defer registry.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const root = try std.fmt.allocPrint(a, "{s}/sessions", .{base});
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = root });
    const first = try rt.createSession(project_a);
    const id = try a.dupe(u8, first.id);
    const empty = try rt.createSession(project_a);
    const empty_id = try a.dupe(u8, empty.id);
    try std.testing.expect(!(try move(&rt, a, id, project_a)).moved);
    try std.testing.expect((try move(&rt, a, empty_id, project_b)).moved);
    try std.testing.expectEqual(@as(usize, 0), rt.sessions.get(empty_id).?.session.messages.items.len);
    try std.testing.expect(rt.sessions.get(empty_id).?.session.file == null);
    try rt.sessions.get(empty_id).?.session.append(.{ .id = "msg_empty", .role = .user, .content = &.{.{ .text = "new" }}, .timestamp = 1 });
    const entry = rt.sessions.get(id).?;
    entry.pending_options = .{};
    try std.testing.expectError(error.SessionBusy, move(&rt, a, id, project_b));
    entry.pending_options = null;
    try entry.session.append(.{ .id = "msg_start", .role = .user, .content = &.{.{ .text = "hello" }}, .timestamp = 1 });
    const old_path = try a.dupe(u8, entry.session.path);
    const old_art = try std.fmt.allocPrint(a, "{s}/{s}.artifacts", .{ std.fs.path.dirname(old_path).?, id });
    _ = try Io.Dir.cwd().createDirPathStatus(io, old_art, .default_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/output.txt", .{old_art}), .data = "saved" });
    try std.testing.expect((try move(&rt, a, id, project_b)).moved);
    const new_path = try a.dupe(u8, entry.session.path);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, old_path, .{}));
    const new_art = try std.fmt.allocPrint(a, "{s}/{s}.artifacts/output.txt", .{ std.fs.path.dirname(new_path).?, id });
    try std.testing.expectEqualStrings("saved", try Io.Dir.cwd().readFileAlloc(io, new_art, a, .limited(100)));
    try std.testing.expectEqualStrings("move", entry.session.messages.items[1].origin.?);
    try std.testing.expect(std.mem.indexOf(u8, try Io.Dir.cwd().readFileAlloc(io, new_path, a, .limited(100000)), "\"location\"") != null);
    rt.deinit();
    const direct = try @import("session.zig").Session.load(gpa, io, root, id, project_b);
    try std.testing.expectEqualStrings(project_b, direct.info.location);
    direct.destroy(gpa, io);
    var restored: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = root });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try restored.restore()).loaded);
    try std.testing.expectEqualStrings(project_b, (try restored.snapshot(a, id)).info.location);
    try std.testing.expectEqualStrings(project_b, (try restored.snapshot(a, empty_id)).info.location);
    try std.testing.expectEqual(@as(usize, 1), (try restored.snapshot(a, empty_id)).messages.len);
    // Simulate a crash after the location update was synced, before rename.
    const recovered = restored.sessions.get(id).?.session;
    try Io.Dir.renameAbsolute(recovered.path, old_path, io);
    recovered.path = old_path;
    try Io.Dir.renameAbsolute(std.fs.path.dirname(new_art).?, old_art, io);
    restored.deinit();
    restored = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = root });
    try std.testing.expectEqual(@as(usize, 2), (try restored.restore()).loaded);
    try std.testing.expectEqualStrings(project_b, (try restored.snapshot(a, id)).info.location);
    try std.testing.expectEqualStrings("saved", try Io.Dir.cwd().readFileAlloc(io, new_art, a, .limited(100)));
}
