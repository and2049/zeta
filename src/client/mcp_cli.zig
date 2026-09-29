//! `zeta mcp [auth|logout <server>]` for the project in the working
//! directory: lists the servers, signs in to one, or forgets a sign-in.
//! Attaches to (or starts) the shared server.
const std = @import("std");
const platform = @import("platform");
const Client = @import("Client.zig");
const attach = @import("attach.zig");
const mcp = @import("mcp.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    paths: platform.Paths,
    exe: []const u8,
    cwd: []const u8,
    /// Try to open the sign-in page in the browser.
    browser: bool = true,
    /// How long `auth` waits for the sign-in.
    wait_ms: i64 = 10 * 60 * 1000,
};

/// Returns the exit status.
pub fn run(gpa: Allocator, io: Io, out: *Io.Writer, args: []const []const u8, o: Options) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const discovery = try attach.attach(gpa, a, io, .{ .paths = o.paths, .exe = o.exe });
    var client = try Client.init(gpa, io, discovery.url, discovery.password);
    defer client.deinit();
    if (args.len == 0) {
        var buf: [4096]u8 = undefined;
        try out.print("{s}\n", .{mcp.summary(&buf, try mcp.list(&client, a, o.cwd))});
        return 0;
    }
    if (args.len != 2) return usage(out);
    const name = args[1];
    if (std.mem.eql(u8, args[0], "logout")) {
        try mcp.logout(&client, a, o.cwd, name);
        try out.print("signed out of {s}\n", .{name});
        return 0;
    }
    if (!std.mem.eql(u8, args[0], "auth")) return usage(out);
    const sign_in = try mcp.auth(&client, a, o.cwd, name);
    try out.print("{s}\n{s}\n", .{ sign_in.instructions, sign_in.url });
    try out.flush();
    if (o.browser) platform.browser.open(io, sign_in.url) catch {};
    const deadline = Io.Clock.awake.now(io).toMilliseconds() + o.wait_ms;
    while (Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        try io.sleep(.fromMilliseconds(500), .awake);
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        for (try mcp.list(&client, scratch.allocator(), o.cwd)) |server| {
            if (!std.mem.eql(u8, server.name, name)) continue;
            const latest = server.signIn orelse {
                try out.print("{s}: the sign-in was cancelled\n", .{name});
                return 1;
            };
            if (latest.id != sign_in.id) {
                try out.print("{s}: another sign-in replaced this one\n", .{name});
                return 1;
            }
            if (std.mem.eql(u8, latest.state, "failed")) {
                try out.print("{s}: the sign-in did not complete\n", .{name});
                return 1;
            }
            // Until the sign-in ends, and the connection it starts settles.
            if (std.mem.eql(u8, latest.state, "running") or std.mem.eql(u8, server.status, "pending")) continue;
            if (std.mem.eql(u8, server.status, "connected")) {
                try out.print("{s} connected ({d} tools)\n", .{ name, server.tools });
                return 0;
            }
            try out.print("{s} {s}: {s}\n", .{ name, server.status, server.@"error" orelse "the sign-in did not complete" });
            return 1;
        }
    }
    try out.print("timed out waiting for the sign-in\n", .{});
    return 1;
}

fn usage(out: *Io.Writer) !u8 {
    try out.writeAll("usage: zeta mcp [auth <server> | logout <server>]\n");
    return 2;
}
