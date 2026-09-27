//! `zeta usage [--all | --session <id>]`: tokens and cost of this project's
//! sessions (every project's with `--all`, one session's with `--session`),
//! overall and per model. Attaches to (or starts) the shared server.
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

const Totals = struct {
    input: u64 = 0,
    output: u64 = 0,
    cacheRead: u64 = 0,
    cacheWrite: u64 = 0,
    cost: f64 = 0,
    messages: usize = 0,
    unpriced: usize = 0,
};
const Report = struct {
    total: Totals = .{},
    models: []const struct { provider: []const u8, model: []const u8, totals: Totals } = &.{},
    sessions: usize = 0,
};

/// Returns the exit status.
pub fn run(gpa: Allocator, io: Io, out: *Io.Writer, args: []const []const u8, o: Options) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path = if (args.len == 0)
        try std.fmt.allocPrint(a, "/usage?location={s}", .{try api.encode(a, o.cwd)})
    else if (args.len == 1 and std.mem.eql(u8, args[0], "--all"))
        "/usage"
    else if (args.len == 2 and std.mem.eql(u8, args[0], "--session"))
        try std.fmt.allocPrint(a, "/sessions/{s}/usage", .{try api.encode(a, args[1])})
    else {
        try out.writeAll("usage: zeta usage [--all | --session <id>]\n");
        return 2;
    };
    const discovery = try attach.attach(gpa, a, io, .{ .paths = o.paths, .exe = o.exe });
    var client = try Client.init(gpa, io, discovery.url, discovery.password);
    defer client.deinit();
    const response = try client.get(a, path);
    api.check(response) catch |err| {
        try out.print("error: {s}\n", .{if (err == error.SessionNotFound) "session not found" else @errorName(err)});
        return 1;
    };
    const report = try std.json.parseFromSliceLeaky(Report, a, response.body, .{ .ignore_unknown_fields = true });
    try write(out, report);
    return 0;
}

fn write(out: *Io.Writer, r: Report) !void {
    try out.print("{d} session{s}, {d} model repl{s}\n", .{ r.sessions, if (r.sessions == 1) "" else "s", r.total.messages, if (r.total.messages == 1) "y" else "ies" });
    try line(out, "total", r.total);
    for (r.models) |m| {
        var buf: [256]u8 = undefined;
        try line(out, std.fmt.bufPrint(&buf, "{s}/{s}", .{ m.provider, m.model }) catch m.model, m.totals);
    }
}

fn line(out: *Io.Writer, name: []const u8, t: Totals) !void {
    try out.print("  {s}: input {d}, output {d}, cache read {d}, cache write {d}, ${d:.4}", .{ name, t.input, t.output, t.cacheRead, t.cacheWrite, t.cost });
    if (t.unpriced > 0) try out.print(" ({d} without a known price)", .{t.unpriced});
    try out.writeByte('\n');
}

test write {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try write(&w, .{ .sessions = 1, .total = .{ .input = 10, .output = 2, .cost = 0.5, .messages = 1 }, .models = &.{.{ .provider = "p", .model = "m", .totals = .{ .input = 10, .output = 2, .cost = 0.5, .messages = 1 } }} });
    try std.testing.expectEqualStrings(
        \\1 session, 1 model reply
        \\  total: input 10, output 2, cache read 0, cache write 0, $0.5000
        \\  p/m: input 10, output 2, cache read 0, cache write 0, $0.5000
        \\
    , w.buffered());
}
