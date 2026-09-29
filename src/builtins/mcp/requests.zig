//! Requests from a server: `roots/list` (the project directory) and
//! `elicitation/create` (asked of the user). Answered from a task of the
//! server, since writing to the server from the reader that received the
//! request could wait on that very reader.
//!
//! A question asked while exactly one `tools/call` is in flight on the
//! link belongs to that call: it carries the call's session, lasts at most
//! as long as the call's deadline, and is withdrawn when the call ends. A
//! server's `notifications/cancelled` for it withdraws it too, and then no
//! reply is sent.
const std = @import("std");
const Server = @import("Server.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

/// A `tools/call` in flight on a link.
pub const Call = struct {
    session: []const u8,
    /// On the awake clock, in milliseconds; null when unknown.
    deadline_ms: ?i64,
};

/// A question the server has open on a link.
pub const Asked = struct {
    /// The request id as JSON text.
    id: []const u8,
    call: ?*Call = null,
    withdrawn: Io.Event = .unset,
    /// The server cancelled the request: send no reply.
    silent: bool = false,
};

/// Questions outside a known call wait this long unless the server has a
/// timeout.
const default_timeout_ms = 120_000;

/// Tracks `call` on `link` until `end`.
pub fn begin(link: *Server.Link, call: *Call) !void {
    const s = link.server;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    try link.calls.append(s.host.gpa, call);
}

/// `call` ended: questions that belong to it are withdrawn.
pub fn end(link: *Server.Link, call: *Call) void {
    const s = link.server;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (link.calls.items, 0..) |c, i| if (c == call) {
        _ = link.calls.swapRemove(i);
        break;
    };
    for (link.questions.items) |q| if (q.call == call) {
        q.call = null;
        q.withdrawn.set(s.io);
    };
}

/// `notifications/cancelled` from the server, on the transport's task.
pub fn cancelled(link: *Server.Link, params: Value) void {
    const s = link.server;
    if (params != .object) return;
    const target = params.object.get("requestId") orelse return;
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    std.json.Stringify.value(target, .{}, &w) catch return;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (link.questions.items) |q| if (std.mem.eql(u8, q.id, w.buffered())) {
        q.silent = true;
        q.withdrawn.set(s.io);
    };
}

/// Whose question `asked` is and how long it may wait; tracked on `link`
/// until `leave`. The session is copied into `a`.
fn enter(s: *Server, link: *Server.Link, a: Allocator, asked: *Asked) !struct { session: ?[]const u8, timeout_ms: u64 } {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    try link.questions.append(s.host.gpa, asked);
    const fallback = s.spec.timeout_ms orelse default_timeout_ms;
    if (link.calls.items.len != 1) return .{ .session = null, .timeout_ms = fallback };
    const call = link.calls.items[0];
    asked.call = call;
    const deadline = call.deadline_ms orelse return .{ .session = try a.dupe(u8, call.session), .timeout_ms = fallback };
    const left = deadline - Io.Clock.awake.now(s.io).toMilliseconds();
    return .{ .session = try a.dupe(u8, call.session), .timeout_ms = @intCast(@max(left, 0)) };
}

/// Stops tracking `asked`; true when the server cancelled it.
fn leave(s: *Server, link: *Server.Link, asked: *Asked) bool {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (link.questions.items, 0..) |q, i| if (q == asked) {
        _ = link.questions.swapRemove(i);
        break;
    };
    return asked.silent;
}

/// `rpc.Notice.request`: true when the request is taken.
pub fn received(ctx: ?*anyopaque, _: Allocator, id: Value, method: []const u8, params: Value) bool {
    const link: *Server.Link = @ptrCast(@alignCast(ctx.?));
    const s = link.server;
    const roots = std.mem.eql(u8, method, "roots/list");
    if (!roots and !(std.mem.eql(u8, method, "elicitation/create") and s.host.asker != null)) return false;
    const gpa = s.host.gpa;
    const copy = std.json.Stringify.valueAlloc(gpa, .{ .id = id, .params = params }, .{}) catch return false;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (!Server.live(link)) {
        gpa.free(copy);
        return true;
    }
    s.tasks.concurrent(s.io, answer, .{ s, link, roots, copy }) catch {
        gpa.free(copy);
        return false;
    };
    return true;
}

fn answer(s: *Server, link: *Server.Link, roots: bool, request: []u8) Io.Cancelable!void {
    defer s.host.gpa.free(request);
    var arena: std.heap.ArenaAllocator = .init(s.host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(Value, a, request, .{}) catch return;
    const id = parsed.object.get("id").?;
    if (roots) return answerRoots(s, link, a, id);
    var asked: Asked = .{ .id = std.json.Stringify.valueAlloc(a, id, .{}) catch return };
    const owner = enter(s, link, a, &asked) catch return link.conn.reply(a, id, .{ .action = "decline" });
    const reply = @import("elicit.zig").answer(s, a, parsed.object.get("params").?, .{
        .session = owner.session,
        .timeout_ms = owner.timeout_ms,
        .withdrawn = &asked.withdrawn,
    });
    if (leave(s, link, &asked)) return;
    const value = reply catch |err| {
        if (err == error.Canceled) return error.Canceled;
        if (err == error.UnsupportedMode) return link.conn.replyError(a, id, -32602, "unsupported elicitation mode");
        return link.conn.reply(a, id, .{ .action = "decline" });
    };
    link.conn.reply(a, id, value);
}

fn answerRoots(s: *Server, link: *Server.Link, a: Allocator, id: Value) void {
    var uri: Io.Writer.Allocating = .init(a);
    uri.writer.writeAll("file://") catch return;
    (std.Uri.Component{ .raw = s.location }).formatPath(&uri.writer) catch return;
    link.conn.reply(a, id, .{ .roots = &[_]struct { uri: []const u8, name: []const u8 }{.{ .uri = uri.written(), .name = std.fs.path.basename(s.location) }} });
}
