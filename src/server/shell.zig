//! Runs the shell commands users start in a session
//! (`POST /sessions/:id/shell`). The request returns once the command is
//! started; it runs here in the background, with no time limit, until it
//! ends or `DELETE /sessions/:id/shell` stops it. core records the result.
const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const Server = @import("Server.zig");
const Ctx = @import("conn.zig").Ctx;
const Io = std.Io;

const Run = struct {
    session: []u8,
    id: []u8,
    command: []u8,
    cwd: []u8,
    stop: platform.command.Stop = .{},
};

pub const Shells = struct {
    mutex: Io.Mutex = .init,
    /// By session id; a run is removed by its own task when it ends.
    running: std.StringHashMapUnmanaged(*Run) = .empty,
    group: Io.Group = .init,

    /// Ends every command (their process groups are killed) and waits.
    pub fn deinit(shells: *Shells, s: *Server) void {
        shells.group.cancel(s.io);
        shells.running.deinit(s.gpa);
    }
};

/// `{"command": "…"}` → `{"id": "msg_…"}`, the id its conversation entry
/// will have. 409 while another of the session's commands runs.
pub fn start(s: *Server, c: *Ctx, session_id: []const u8) !void {
    const body = try c.bodyJson(struct { command: []const u8 });
    if (std.mem.trim(u8, body.command, " \t\r\n").len == 0) return c.fail(.bad_request, "command required");
    const started = s.runtime.shellStart(c.arena, session_id, body.command) catch |err| switch (err) {
        error.ShellBusy => return c.fail(.conflict, "a shell command is already running in this session"),
        else => |e| return e,
    };
    launch(s, session_id, started, body.command) catch |err| {
        s.runtime.shellFinish(session_id, started.id, .{ .output = "The command could not be started." }) catch {};
        return err;
    };
    return c.json(.ok, .{ .id = started.id });
}

fn launch(s: *Server, session_id: []const u8, started: core.shell.Started, command: []const u8) !void {
    const run = try s.gpa.create(Run);
    errdefer s.gpa.destroy(run);
    run.* = .{ .session = try s.gpa.dupe(u8, session_id), .id = undefined, .command = undefined, .cwd = undefined };
    errdefer s.gpa.free(run.session);
    run.id = try s.gpa.dupe(u8, started.id);
    errdefer s.gpa.free(run.id);
    run.command = try s.gpa.dupe(u8, command);
    errdefer s.gpa.free(run.command);
    run.cwd = try s.gpa.dupe(u8, started.location);
    errdefer s.gpa.free(run.cwd);
    const shells = &s.shells;
    shells.mutex.lockUncancelable(s.io);
    defer shells.mutex.unlock(s.io);
    try shells.running.put(s.gpa, run.session, run);
    errdefer _ = shells.running.remove(run.session);
    try shells.group.concurrent(s.io, execute, .{ s, run });
}

/// Stops the session's running command; 404 when there is none.
pub fn stop(s: *Server, c: *Ctx, session_id: []const u8) !void {
    const shells = &s.shells;
    shells.mutex.lockUncancelable(s.io);
    const found = shells.running.get(session_id);
    if (found) |run| run.stop.request();
    shells.mutex.unlock(s.io);
    if (found == null) return c.fail(.not_found, "no shell command is running");
    return c.json(.ok, .{ .ok = true });
}

fn execute(s: *Server, run: *Run) Io.Cancelable!void {
    defer {
        s.shells.mutex.lockUncancelable(s.io);
        _ = s.shells.running.remove(run.session);
        s.shells.mutex.unlock(s.io);
        for ([_][]u8{ run.session, run.id, run.command, run.cwd }) |bytes| s.gpa.free(bytes);
        s.gpa.destroy(run);
    }
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result: core.shell.Result = if (platform.command.runStoppable(arena, s.io, run.cwd, run.command, null, &run.stop)) |output|
        describe(arena, output) catch .{ .output = "The command's output could not be kept." }
    else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => .{ .output = std.fmt.allocPrint(arena, "The command could not be run: {t}", .{err}) catch "The command could not be run." },
    };
    s.runtime.shellFinish(run.session, run.id, result) catch |err| std.log.warn("shell command result not recorded: {t}", .{err});
}

/// The output with closing lines saying what was cut and how it ended.
fn describe(arena: std.mem.Allocator, output: platform.command.Output) !core.shell.Result {
    const exit_code: ?u8 = if (!output.stopped and output.term == .exited) output.term.exited else null;
    const status: []const u8 = if (output.stopped)
        "Stopped by the user"
    else switch (output.term) {
        .exited => |code| if (code == 0) "" else try std.fmt.allocPrint(arena, "Command exited with code {d}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(arena, "Command terminated by signal {d}", .{@intFromEnum(signal)}),
        else => "Command terminated without an exit code",
    };
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, std.mem.trimEnd(u8, output.text, "\r\n"));
    for ([_][]const u8{ if (output.truncated) "[Output truncated to last 2000 lines / 50 KB]" else "", status }) |line| {
        if (line.len == 0) continue;
        if (text.items.len > 0) try text.append(arena, '\n');
        try text.appendSlice(arena, line);
    }
    return .{ .output = if (text.items.len == 0) "(no output)" else text.items, .exit_code = exit_code, .stopped = output.stopped, .truncated = output.truncated };
}

test "the result says how the command ended" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = try describe(a, .{ .text = "hi\n", .truncated = false, .term = .{ .exited = 0 } });
    try std.testing.expectEqualStrings("hi", ok.output);
    try std.testing.expectEqual(@as(?u8, 0), ok.exit_code);
    const failed = try describe(a, .{ .text = "", .truncated = false, .term = .{ .exited = 3 } });
    try std.testing.expectEqualStrings("Command exited with code 3", failed.output);
    const stopped = try describe(a, .{ .text = "partial\n", .truncated = true, .term = .{ .signal = .KILL }, .stopped = true });
    try std.testing.expectEqualStrings("partial\n[Output truncated to last 2000 lines / 50 KB]\nStopped by the user", stopped.output);
    try std.testing.expect(stopped.exit_code == null and stopped.stopped);
    try std.testing.expectEqualStrings("(no output)", (try describe(a, .{ .text = "", .truncated = false, .term = .{ .exited = 0 } })).output);
}
