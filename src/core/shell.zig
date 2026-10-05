//! Shell commands the user runs themselves in a session. The process runs
//! outside core (the server owns it); this tracks the one running per
//! session and records its result in the conversation: at once when the
//! agent is idle, without starting a turn, or through the inbox at the
//! running turn's next step.
const std = @import("std");
const proto = @import("proto");
const Runtime = @import("Runtime.zig");
const Item = @import("inbox.zig").Item;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const types = proto.event.types;

/// `Message.origin` of a recorded command. Its content is two text parts:
/// the command, then what it printed.
pub const origin = "shell";

/// A command in progress. `id` becomes its message id.
pub const Running = struct {
    id: []const u8,
    command: []const u8,
    startedAt: i64,
};

pub const Result = struct {
    /// What the command printed, with a closing line on how it ended.
    output: []const u8,
    /// Null when a signal or a stop ended it.
    exit_code: ?u8 = null,
    stopped: bool = false,
    truncated: bool = false,

    fn failed(r: Result) bool {
        return r.stopped or r.exit_code == null or r.exit_code.? != 0;
    }
};

pub const Started = struct { id: []const u8, location: []const u8 };

/// Marks `command` as running in the session and announces it
/// (`shell.started`). One at a time: `error.ShellBusy` otherwise. The
/// result's strings belong to `arena`.
pub fn start(rt: *Runtime, arena: Allocator, session_id: []const u8, command: []const u8) !Started {
    const id = rt.ids.next(rt.io, .message);
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(session_id) orelse return error.SessionNotFound;
    if (entry.stopping) return error.SessionBusy;
    if (entry.shell != null) return error.ShellBusy;
    const id_copy = try rt.gpa.dupe(u8, id.slice());
    errdefer rt.gpa.free(id_copy);
    const running: Running = .{ .id = id_copy, .command = try rt.gpa.dupe(u8, command), .startedAt = Io.Clock.real.now(rt.io).toMilliseconds() };
    entry.shell = running;
    const info = entry.session.info;
    rt.bus.publishValue(types.shell_started, info.id, info.location, running) catch {};
    return .{ .id = try arena.dupe(u8, id_copy), .location = try arena.dupe(u8, info.location) };
}

/// The command `id` ended: announces it (`shell.ended`) and records it.
/// Does nothing when the session or the command is no longer there.
pub fn finish(rt: *Runtime, session_id: []const u8, id: []const u8, result: Result) !void {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(session_id) orelse return;
    const running = entry.shell orelse return;
    if (!std.mem.eql(u8, running.id, id)) return;
    entry.shell = null;
    defer free(rt, running);
    const info = entry.session.info;
    rt.bus.publishValue(types.shell_ended, info.id, info.location, .{
        .id = running.id,
        .command = running.command,
        .output = result.output,
        .exitCode = result.exit_code,
        .stopped = result.stopped,
        .truncated = result.truncated,
    }) catch {};
    if (entry.stopping) return;
    if (entry.running) {
        try entry.inbox.pushShell(running.id, running.command, result.output, result.failed());
        rt.publishInbox(entry);
        return;
    }
    try append(rt, entry, .{ .id = running.id, .text = running.command, .delivery = .steer, .kind = .shell, .output = result.output, .failed = result.failed() });
}

/// Records every shell result still waiting in the inbox, for when no
/// turn will take them. Caller holds rt.mutex.
pub fn flush(rt: *Runtime, entry: *Runtime.Entry) !void {
    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    var any = false;
    while (try entry.inbox.takeShell(arena.allocator())) |item| {
        try append(rt, entry, item);
        entry.inbox.ack(item.id);
        any = true;
    }
    if (any) rt.publishInbox(entry);
}

/// Frees what a session's running command holds. Caller holds rt.mutex or
/// owns the entry.
pub fn drop(rt: *Runtime, entry: *Runtime.Entry) void {
    if (entry.shell) |running| free(rt, running);
    entry.shell = null;
}

fn free(rt: *Runtime, running: Running) void {
    rt.gpa.free(running.id);
    rt.gpa.free(running.command);
}

fn append(rt: *Runtime, entry: *Runtime.Entry, item: Item) !void {
    var parts: [2]proto.message.Content = undefined;
    const m = message(&parts, item, Io.Clock.real.now(rt.io).toMilliseconds());
    try entry.session.append(m);
    const info = entry.session.info;
    try rt.bus.publishValue(types.message_start, info.id, info.location, .{ .message = m });
    try rt.bus.publishValue(types.message_end, info.id, info.location, .{ .message = m });
}

/// The conversation entry for a shell inbox item. Borrows `parts` and the
/// item's strings.
pub fn message(parts: *[2]proto.message.Content, item: Item, timestamp: i64) proto.Message {
    parts.* = .{ .{ .text = item.text }, .{ .text = item.output } };
    return .{ .id = item.id, .role = .user, .content = parts, .timestamp = timestamp, .origin = origin, .isError = item.failed };
}

pub fn is(m: proto.Message) bool {
    const o = m.origin orelse return false;
    return m.role == .user and std.mem.eql(u8, o, origin) and m.content.len == 2 and m.content[0] == .text and m.content[1] == .text;
}

/// What the model reads for a recorded command.
pub fn modelText(arena: Allocator, m: proto.Message) ![]const u8 {
    return std.fmt.allocPrint(arena, "The user ran a shell command themselves. It is shown for your information; do not run it again unless asked.\n\nCommand:\n{s}\n\nOutput:\n{s}", .{ m.content[0].text, m.content[1].text });
}

test "an idle session records the command without a turn; one runs at a time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bus: @import("bus.zig").Bus = .init(gpa, io);
    defer bus.deinit();
    var registry: @import("plugin").Registry = .init(gpa, io);
    defer registry.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var rt: Runtime = .init(gpa, io, &bus, &registry, &env, .{ .config_dir = base, .sessions_dir = try std.fmt.allocPrint(a, "{s}/sessions", .{base}) });
    defer rt.deinit();
    const id = try a.dupe(u8, (try rt.createSession(base)).id);
    try std.testing.expectError(error.SessionNotFound, start(&rt, a, "ses_none", "ls"));

    const first = try start(&rt, a, id, "echo hi");
    try std.testing.expectError(error.ShellBusy, start(&rt, a, id, "ls"));
    try std.testing.expectEqualStrings("echo hi", (try rt.snapshot(a, id)).shell.?.command);
    try finish(&rt, id, "msg_other", .{ .output = "x", .exit_code = 0 });
    try std.testing.expect(rt.sessions.get(id).?.shell != null);
    try finish(&rt, id, first.id, .{ .output = "hi\n", .exit_code = 0 });
    const entry = rt.sessions.get(id).?;
    try std.testing.expect(entry.shell == null and !entry.running);
    const recorded = entry.session.messages.items;
    try std.testing.expectEqual(@as(usize, 1), recorded.len);
    try std.testing.expect(is(recorded[0]) and !recorded[0].isError);
    try std.testing.expectEqualStrings(first.id, recorded[0].id);
    try std.testing.expect(std.mem.endsWith(u8, try modelText(a, recorded[0]), "Command:\necho hi\n\nOutput:\nhi\n"));

    // While a turn runs the result waits in the inbox; nothing taking it,
    // it is recorded all the same.
    const second = try start(&rt, a, id, "false");
    entry.running = true;
    try finish(&rt, id, second.id, .{ .output = "Command exited with code 1", .exit_code = 1 });
    try std.testing.expectEqual(@as(usize, 1), entry.session.messages.items.len);
    try std.testing.expect(!entry.inbox.isEmpty());
    entry.running = false;
    rt.mutex.lockUncancelable(io);
    try flush(&rt, entry);
    rt.mutex.unlock(io);
    try std.testing.expect(entry.inbox.isEmpty());
    try std.testing.expect(entry.session.messages.items[1].isError);

    // A command still running when its session goes is forgotten.
    const third = try start(&rt, a, id, "sleep 9");
    try rt.deleteSession(id);
    try finish(&rt, id, third.id, .{ .output = "" });
}
