//! `zeta sessions [--all] [<text>]` lists this project's sessions (every
//! project's with `--all`), newest first, those mentioning `<text>` when
//! given; `zeta sessions export <id>` prints one as JSONL. Attaches to (or
//! starts) the shared server. `zeta undo [--session <id>]` undoes the file
//! changes of the latest reply (in the project's newest session by default).
const std = @import("std");
const platform = @import("platform");
const Client = @import("Client.zig");
const attach = @import("attach.zig");
const api = @import("session_api.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    paths: platform.Paths,
    exe: []const u8,
    cwd: []const u8,
};

/// Returns the exit status.
pub fn run(gpa: Allocator, io: Io, out: *Io.Writer, args: []const []const u8, o: Options) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const exporting = args.len > 0 and std.mem.eql(u8, args[0], "export");
    if (exporting and args.len != 2) return usage(out);
    const all = !exporting and args.len > 0 and std.mem.eql(u8, args[0], "--all");
    const words = if (exporting) &.{} else args[@intFromBool(all)..];
    const discovery = try attach.attach(gpa, a, io, .{ .paths = o.paths, .exe = o.exe });
    var client = try Client.init(gpa, io, discovery.url, discovery.password);
    defer client.deinit();
    if (exporting) {
        const response = try client.get(a, try std.fmt.allocPrint(a, "/sessions/{s}/export", .{try api.encode(a, args[1])}));
        api.check(response) catch |err| {
            try out.print("error: {s}\n", .{if (err == error.SessionNotFound) "session not found" else @errorName(err)});
            return 1;
        };
        try out.writeAll(response.body);
        return 0;
    }
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(a, "/sessions?");
    if (!all) try path.print(a, "location={s}&", .{try api.encode(a, o.cwd)});
    if (words.len > 0) try path.print(a, "q={s}", .{try api.encode(a, try std.mem.join(a, " ", words))});
    const response = try client.get(a, path.items);
    try api.check(response);
    const sessions = try std.json.parseFromSliceLeaky([]const api.Info, a, response.body, .{ .ignore_unknown_fields = true });
    for (sessions) |s| try line(out, s, all);
    return 0;
}

/// `zeta undo`; returns the exit status.
pub fn undo(gpa: Allocator, io: Io, out: *Io.Writer, args: []const []const u8, o: Options) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (!(args.len == 0 or (args.len == 2 and std.mem.eql(u8, args[0], "--session")))) {
        try out.writeAll("usage: zeta undo [--session <id>]\n");
        return 2;
    }
    const discovery = try attach.attach(gpa, a, io, .{ .paths = o.paths, .exe = o.exe });
    var client = try Client.init(gpa, io, discovery.url, discovery.password);
    defer client.deinit();
    const id = if (args.len == 2) args[1] else blk: {
        const sessions = try api.list(&client, a, o.cwd);
        if (sessions.len == 0) {
            try out.writeAll("No sessions in this project.\n");
            return 1;
        }
        break :blk sessions[0].id;
    };
    const done = api.undo(&client, a, id) catch |err| {
        try out.print("error: {s}\n", .{switch (err) {
            error.SessionNotFound => "session not found",
            error.SessionBusy => "the session is running; abort it first",
            else => @errorName(err),
        }});
        return 1;
    };
    var buf: [1024]u8 = undefined;
    try out.print("{s}\n", .{api.undoSummary(&buf, done)});
    return if (done == null) 1 else 0;
}

fn usage(out: *Io.Writer) !u8 {
    try out.writeAll("usage: zeta sessions [--all] [<text>] | zeta sessions export <id>\n");
    return 2;
}

/// `<id>  <YYYY-MM-DD HH:MM> UTC  <title>` (and the project with `--all`);
/// the time is the session's latest activity.
fn line(out: *Io.Writer, s: api.Info, all: bool) !void {
    const secs: u64 = @intCast(@max(@divFloor(s.updated orelse s.created, 1000), 0));
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const ymd = day.calculateYearDay();
    const md = ymd.calculateMonthDay();
    const in_day = (std.time.epoch.EpochSeconds{ .secs = secs }).getDaySeconds();
    try out.print("{s}  {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}  {s}", .{ s.id, ymd.year, md.month.numeric(), md.day_index + 1, in_day.getHoursIntoDay(), in_day.getMinutesIntoHour(), s.title orelse "(untitled)" });
    if (all) try out.print("  {s}", .{s.location});
    try out.writeByte('\n');
}

test line {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try line(&w, .{ .id = "ses_1", .location = "/p", .created = 1_790_000_000_000, .title = "Fix tests" }, true);
    try std.testing.expectEqualStrings("ses_1  2026-09-21 14:13  Fix tests  /p\n", w.buffered());
}
