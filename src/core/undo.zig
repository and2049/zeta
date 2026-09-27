//! Undoing the file changes of the latest reply. Before a tool changes a
//! file it asks the host to keep the file (`ProgressSink.backup`); the copy
//! goes beside the session log (`<session>.artifacts/undo/`) and a line in
//! `undo/changes.ndjson` records it. When the call ends, the file's new state is
//! recorded too. Undo takes the newest reply with changes left, and puts
//! back each file it changed as it was before that reply, unless the file
//! has changed since (then it is left alone and reported).
const std = @import("std");
const proto = @import("proto");
const Runtime = @import("Runtime.zig");
const artifacts = @import("artifacts.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Files larger than this are not kept (and cannot be undone).
const max_file = 64 * 1024 * 1024;

const Line = struct {
    call: ?[]const u8 = null,
    path: ?[]const u8 = null,
    existed: ?bool = null,
    /// Name of the copy in `undo/`; null for a file that did not exist.
    backup: ?[]const u8 = null,
    /// Hash of the file after the call; null when it was gone.
    after: ?[]const u8 = null,
    settled: bool = false,
    undone: ?[]const u8 = null,
};

fn append(io: Io, directory: []const u8, line: Line) !void {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/undo/changes.ndjson", .{directory});
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer file.close(io);
    var out: [8192]u8 = undefined;
    var w = file.writer(io, &out);
    try w.seekTo(try file.length(io));
    try std.json.Stringify.value(line, .{ .emit_null_optional_fields = false }, &w.interface);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}

fn hash(arena: Allocator, io: Io, path: []const u8) !?[]const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return try std.fmt.allocPrint(arena, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)});
}

/// Keeps `path` as it is now, for call `call` (its `n`th file).
pub fn backup(arena: Allocator, io: Io, directory: []const u8, call: []const u8, n: usize, path: []const u8) !void {
    _ = try Io.Dir.cwd().createDirPathStatus(io, try std.fmt.allocPrint(arena, "{s}/undo", .{directory}), .fromMode(0o700));
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => return append(io, directory, .{ .call = call, .path = path, .existed = false }),
        else => |e| return e,
    };
    const safe = try arena.dupe(u8, call);
    for (safe) |*c| if (!std.ascii.isAlphanumeric(c.*) and c.* != '_' and c.* != '-') {
        c.* = '_';
    };
    const name = try std.fmt.allocPrint(arena, "{s}-{d}.bak", .{ safe, n });
    var atomic = try Io.Dir.cwd().createFileAtomic(io, try std.fmt.allocPrint(arena, "{s}/undo/{s}", .{ directory, name }), .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
    try append(io, directory, .{ .call = call, .path = path, .existed = true, .backup = name });
}

/// Records the state `paths` were left in by call `call`.
pub fn settle(arena: Allocator, io: Io, directory: []const u8, call: []const u8, paths: []const []const u8) !void {
    for (paths) |path| try append(io, directory, .{ .call = call, .path = path, .after = try hash(arena, io, path), .settled = true });
}

pub const File = struct { path: []const u8, restored: bool };
pub const Result = struct { messageId: []const u8, files: []const File };

/// Per path within the reply: its state before (the first backup) and
/// after (the last settled hash).
const Plan = struct { path: []const u8, existed: bool, backup: ?[]const u8, after: ?[]const u8, settled: bool };

/// Undoes the file changes of the session's newest reply that has some
/// left; null when there is none. The session must be idle.
pub fn undo(rt: *Runtime, arena: Allocator, id: []const u8) !?Result {
    const entry, const directory, const messages = blk: {
        rt.mutex.lockUncancelable(rt.io);
        defer rt.mutex.unlock(rt.io);
        const e = rt.sessions.get(id) orelse return error.SessionNotFound;
        if (e.running or e.pending_options != null) return error.SessionBusy;
        const snapshot = try e.session.snapshot(arena);
        break :blk .{ e, try artifacts.dir(arena, rt.sessions_dir, e.session.info.location, id), snapshot.messages };
    };
    const text = Io.Dir.cwd().readFileAlloc(rt.io, try std.fmt.allocPrint(arena, "{s}/undo/changes.ndjson", .{directory}), arena, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    var lines: std.ArrayList(Line) = .empty;
    var undone: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.json.parseFromSliceLeaky(Line, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (line.undone) |m| try undone.put(arena, m, {}) else try lines.append(arena, line);
    }
    // The newest reply, not yet undone, whose calls kept files.
    var index = messages.len;
    const reply, const calls = while (index > 0) {
        index -= 1;
        const m = messages[index];
        if (m.role != .assistant or undone.contains(m.id)) continue;
        var ids: std.ArrayList([]const u8) = .empty;
        for (m.content) |c| if (c == .tool_call) for (lines.items) |l| if (l.call != null and std.mem.eql(u8, l.call.?, c.tool_call.id)) {
            try ids.append(arena, c.tool_call.id);
            break;
        };
        if (ids.items.len > 0) break .{ m, ids.items };
    } else return null;
    var plans: std.ArrayList(Plan) = .empty;
    for (lines.items) |l| {
        const call = l.call orelse continue;
        const path = l.path orelse continue;
        const mine = for (calls) |c| {
            if (std.mem.eql(u8, c, call)) break true;
        } else false;
        if (!mine) continue;
        const plan = for (plans.items) |*p| {
            if (std.mem.eql(u8, p.path, path)) break p;
        } else blk: {
            try plans.append(arena, .{ .path = path, .existed = l.existed orelse false, .backup = l.backup, .after = null, .settled = false });
            break :blk &plans.items[plans.items.len - 1];
        };
        if (l.settled) {
            plan.after = l.after;
            plan.settled = true;
        }
    }
    const files = try arena.alloc(File, plans.items.len);
    for (plans.items, files) |p, *f| f.* = .{ .path = p.path, .restored = try restore(rt.io, arena, directory, p) };
    try append(rt.io, directory, .{ .undone = reply.id });
    try note(rt, arena, entry, files);
    return .{ .messageId = reply.id, .files = files };
}

/// Tells the model, in the conversation, what the undo did.
fn note(rt: *Runtime, arena: Allocator, entry: *Runtime.Entry, files: []const File) !void {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "The user undid the file changes of an earlier reply of yours.");
    for ([_]bool{ true, false }) |restored| {
        var first = true;
        for (files) |f| if (f.restored == restored) {
            try text.appendSlice(arena, if (!first) ", " else if (restored) " Restored: " else " Left as they are now (changed since): ");
            try text.appendSlice(arena, f.path);
            first = false;
        };
        if (!first) try text.append(arena, '.');
    }
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    if (entry.running) return;
    const id = rt.ids.next(rt.io, .message);
    const message: proto.Message = .{
        .id = id.slice(),
        .role = .user,
        .content = &.{.{ .text = text.items }},
        .timestamp = Io.Clock.real.now(rt.io).toMilliseconds(),
        .origin = "undo",
    };
    try entry.session.append(message);
    const info = entry.session.info;
    try rt.bus.publishValue(proto.event.types.message_start, info.id, info.location, .{ .message = message });
    try rt.bus.publishValue(proto.event.types.message_end, info.id, info.location, .{ .message = message });
}

/// Puts `p.path` back as it was, if it is still as the reply left it.
fn restore(io: Io, arena: Allocator, directory: []const u8, p: Plan) !bool {
    if (!p.settled) return false;
    const now = try hash(arena, io, p.path);
    const same = if (now) |h| (if (p.after) |a| std.mem.eql(u8, h, a) else false) else p.after == null;
    if (!same) return false;
    if (!p.existed) {
        Io.Dir.cwd().deleteFile(io, p.path) catch |err| if (err != error.FileNotFound) return err;
        return true;
    }
    const bytes = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/undo/{s}", .{ directory, p.backup orelse return false }), arena, .limited(max_file));
    if (std.fs.path.dirname(p.path)) |parent| _ = try Io.Dir.cwd().createDirPathStatus(io, parent, .default_dir);
    var atomic = try Io.Dir.cwd().createFileAtomic(io, p.path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
    return true;
}

test "backups settle and restore; a file changed since is left alone" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const dir = try std.fmt.allocPrint(a, "{s}/s.artifacts", .{root});
    _ = try Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    const kept = try std.fmt.allocPrint(a, "{s}/kept.txt", .{root});
    const made = try std.fmt.allocPrint(a, "{s}/made.txt", .{root});
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "old" });
    try backup(a, io, dir, "c1", 1, kept);
    try backup(a, io, dir, "c1", 2, made);
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "made.txt", .data = "fresh" });
    try settle(a, io, dir, "c1", &.{ kept, made });
    const text = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/undo/changes.ndjson", .{dir}), a, .limited(1 << 20));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, "\n"));
    // Plans as `undo` builds them.
    try std.testing.expect(try restore(io, a, dir, .{ .path = kept, .existed = true, .backup = "c1-1.bak", .after = (try hash(a, io, kept)), .settled = true }));
    try std.testing.expectEqualStrings("old", try tmp.dir.readFileAlloc(io, "kept.txt", a, .limited(64)));
    try tmp.dir.writeFile(io, .{ .sub_path = "made.txt", .data = "edited by the user" });
    try std.testing.expect(!try restore(io, a, dir, .{ .path = made, .existed = false, .backup = null, .after = "0000000000000000", .settled = true }));
    try std.testing.expect(try restore(io, a, dir, .{ .path = made, .existed = false, .backup = null, .after = (try hash(a, io, made)), .settled = true }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "made.txt", .{}));
}
