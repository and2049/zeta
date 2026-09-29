//! Handles MCP transport notifications and connection closure callbacks.
const std = @import("std");
const Server = @import("Server.zig");
const Link = Server.Link;
const live = Server.live;
const requests = @import("requests.zig");
const listing = @import("listing.zig");
const Io = std.Io;
const Value = std.json.Value;

/// Starts `func` for a transport callback while `link` is the live,
/// connected attempt. Checked and
/// scheduled under the lock, so nothing is added once stopping has begun
/// and the final `tasks.cancel` joins everything.
fn spawn(link: *Link, comptime func: anytype, extra: anytype, what: []const u8) void {
    const s = link.server;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (!live(link) or s.state != .connected) return;
    s.tasks.concurrent(s.io, func, .{ s, link } ++ extra) catch |err| std.log.warn("mcp {s}: cannot {s}: {s}", .{ s.spec.name, what, @errorName(err) });
}

pub fn notified(ctx: ?*anyopaque, method: []const u8, params: Value) void {
    const link: *Link = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, method, "notifications/cancelled")) return requests.cancelled(link, params);
    if (!std.mem.eql(u8, method, "notifications/tools/list_changed") and !std.mem.eql(u8, method, "notifications/prompts/list_changed")) return;
    spawn(link, relist, .{}, "list tools again");
}

fn relist(s: *Server, link: *Link) Io.Cancelable!void {
    s.mutex.lockUncancelable(s.io);
    const go = s.state == .connected and live(link);
    s.mutex.unlock(s.io);
    if (!go) return;
    listing.refresh(s, link) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        if (err == error.McpUnauthorized and s.signsIn()) return s.refused(link);
        std.log.warn("mcp {s}: listing tools again failed: {s}", .{ s.spec.name, @errorName(err) });
    };
}

pub fn closed(ctx: ?*anyopaque, reason: []const u8) void {
    const link: *Link = @ptrCast(@alignCast(ctx.?));
    // While connecting, the failing request reports it; stale attempts
    // and stopping servers are not news. This runs on the transport's own
    // reader, which stopping the transport waits for; fail from a task of
    // the server instead.
    spawn(link, failLater, .{reason}, "report the disconnect");
}

fn failLater(s: *Server, link: *Link, reason: []const u8) Io.Cancelable!void {
    s.fail(link, reason);
}
