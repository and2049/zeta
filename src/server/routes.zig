const std = @import("std");
const proto = @import("proto");
const core = @import("core");
const plugin = @import("plugin");
const Server = @import("Server.zig");
const conn = @import("conn.zig");
const Ctx = conn.Ctx;
const admin = @import("admin_routes.zig");
const auth_routes = @import("auth_routes.zig");
const query = @import("query.zig");
const session_actions = @import("session_actions.zig");
const file_routes = @import("file_routes.zig");

pub fn dispatch(s: *Server, c: *Ctx) !void {
    var seg_buf: [8][]const u8 = undefined;
    const seg = conn.segments(c.path, &seg_buf);

    if (seg.len >= 2 and std.mem.eql(u8, seg[0], "auth")) return auth_routes.dispatch(s, c, seg);
    if (seg.len >= 1 and seg.len <= 2 and std.mem.eql(u8, seg[0], "files")) {
        if (seg.len == 1) return file_routes.dispatch(c, "list");
        if (std.mem.eql(u8, seg[1], "find") or std.mem.eql(u8, seg[1], "read")) return file_routes.dispatch(c, seg[1]);
    }
    if (seg.len == 1 and std.mem.eql(u8, seg[0], "directories")) return file_routes.directories(c);

    if (seg.len == 2 and std.mem.eql(u8, seg[0], "server") and std.mem.eql(u8, seg[1], "stop")) return admin.stop(s, c);
    if (seg.len == 2 and std.mem.eql(u8, seg[0], "registry") and std.mem.eql(u8, seg[1], "reload")) return admin.reload(s, c);
    if (seg.len == 1 and std.mem.eql(u8, seg[0], "mcp")) return admin.loaderStatus(s, c, "mcp", "servers");
    // Server names may be any string: the client percent-encodes them.
    if (seg.len == 3 and std.mem.eql(u8, seg[0], "mcp") and std.mem.eql(u8, seg[2], "connect")) return admin.loaderRetry(s, c, "mcp", try decoded(c.arena, seg[1]), "mcp server not found");
    if (seg.len == 3 and std.mem.eql(u8, seg[0], "mcp") and std.mem.eql(u8, seg[2], "auth")) return admin.loaderAuth(s, c, "mcp", try decoded(c.arena, seg[1]), "mcp server not found");
    if ((seg.len == 1 or seg.len == 2) and std.mem.eql(u8, seg[0], "credentials")) return admin.credentials(s, c, if (seg.len == 2) seg[1] else null);
    if (seg.len == 1) {
        if (std.mem.eql(u8, seg[0], "config") and c.method == .PATCH) return admin.patchConfig(s, c);
        if (std.mem.eql(u8, seg[0], "commands")) return admin.commands(s, c);
        for ([_][]const u8{ "config", "models", "registry" }) |kind| {
            if (std.mem.eql(u8, seg[0], kind)) return admin.read(s, c, kind);
        }
    }

    if (seg.len == 1 and std.mem.eql(u8, seg[0], "usage")) {
        if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
        const raw = try query.get(c.arena, c.query, "location");
        const location = if (raw) |loc| try core.location.resolve(c.arena, c.io, loc) else null;
        const since = if (try query.get(c.arena, c.query, "since")) |text| std.fmt.parseInt(i64, text, 10) catch return c.fail(.bad_request, "since must be Unix milliseconds") else 0;
        return c.json(.ok, try core.usage.ofAll(s.runtime, c.arena, location, since));
    }
    if (seg.len == 1 and std.mem.eql(u8, seg[0], "health")) {
        if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
        return health(s, c);
    }
    if (seg.len == 1 and std.mem.eql(u8, seg[0], "event")) {
        if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
        return events(s, c);
    }
    if (seg.len == 1 and std.mem.eql(u8, seg[0], "sessions")) {
        if (c.method == .GET) {
            const raw = try query.get(c.arena, c.query, "location");
            const location = if (raw) |loc| try core.location.resolve(c.arena, c.io, loc) else null;
            const q = try query.get(c.arena, c.query, "q");
            return c.json(.ok, try s.runtime.listSessions(c.arena, location, if (q) |text| if (text.len > 0) text else null else null));
        }
        if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
        return createSession(s, c);
    }
    if (seg.len == 2 and std.mem.eql(u8, seg[0], "sessions")) {
        if (c.method == .PATCH) return session_actions.patchSession(s, c, seg[1]);
        if (c.method == .GET) return c.json(.ok, try s.runtime.snapshot(c.arena, seg[1]));
        if (c.method == .DELETE) {
            try s.runtime.deleteSession(seg[1]);
            return c.json(.ok, .{ .ok = true });
        }
        return c.fail(.method_not_allowed, "method not allowed");
    }
    if (seg.len == 4 and std.mem.eql(u8, seg[0], "sessions") and std.mem.eql(u8, seg[2], "inbox")) {
        return session_actions.deleteInboxItem(s, c, seg[1], seg[3]);
    }
    if (seg.len == 3 and std.mem.eql(u8, seg[0], "sessions")) {
        if (std.mem.eql(u8, seg[2], "title")) return session_actions.generateTitle(s, c, seg[1]);
        if (std.mem.eql(u8, seg[2], "compact")) return session_actions.compact(s, c, seg[1]);
        if (std.mem.eql(u8, seg[2], "fork")) return session_actions.fork(s, c, seg[1]);
        if (std.mem.eql(u8, seg[2], "move")) return session_actions.move(s, c, seg[1]);
        if (std.mem.eql(u8, seg[2], "undo")) {
            if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
            const done = (try core.undo.undo(s.runtime, c.arena, seg[1])) orelse return c.fail(.not_found, "nothing to undo");
            return c.json(.ok, done);
        }
        if (std.mem.eql(u8, seg[2], "export")) {
            if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
            return c.send(.ok, "application/x-ndjson", try core.session_search.exportJsonl(s.runtime, c.arena, seg[1]));
        }
        if (std.mem.eql(u8, seg[2], "usage")) {
            if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
            return c.json(.ok, try core.usage.ofSession(s.runtime, c.arena, seg[1]));
        }
        if (std.mem.eql(u8, seg[2], "abort")) {
            if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
            try s.runtime.abort(seg[1]);
            return c.json(.ok, .{ .ok = true });
        }
        if (std.mem.eql(u8, seg[2], "messages")) {
            if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
            const before = try query.get(c.arena, c.query, "before");
            const raw_limit = try query.get(c.arena, c.query, "limit");
            const limit = if (raw_limit) |raw| std.fmt.parseInt(usize, raw, 10) catch return error.InvalidLimit else 50;
            if (limit == 0 or limit > 200) return error.InvalidLimit;
            return c.json(.ok, try s.runtime.messages(c.arena, seg[1], before, limit));
        }
    }
    if (seg.len == 3 and std.mem.eql(u8, seg[0], "sessions") and std.mem.eql(u8, seg[2], "prompt")) {
        if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
        return prompt(s, c, seg[1]);
    }
    if (seg.len == 3 and std.mem.eql(u8, seg[0], "sessions") and std.mem.eql(u8, seg[2], "command")) {
        if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
        return command(s, c, seg[1]);
    }
    if (seg.len == 3 and std.mem.eql(u8, seg[0], "permissions") and std.mem.eql(u8, seg[2], "reply")) {
        if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
        return permissionReply(s, c, seg[1]);
    }
    if (seg.len == 1 and std.mem.eql(u8, seg[0], "elicitations")) return admin.elicitations(s, c);
    if (seg.len == 3 and std.mem.eql(u8, seg[0], "elicitations") and std.mem.eql(u8, seg[2], "reply")) return admin.elicitationReply(s, c, seg[1]);
}

/// `{"reply":"allow_once"|"allow_session"|"deny"}`.
fn permissionReply(s: *Server, c: *Ctx, id: []const u8) !void {
    const body = try c.bodyJson(struct { reply: []const u8 });
    const answer = std.meta.stringToEnum(core.permissions.Reply, body.reply) orelse
        return c.fail(.bad_request, "invalid permission reply");
    if (!s.runtime.replyPermission(id, answer)) return c.fail(.not_found, "permission request not pending");
    try c.json(.ok, .{ .ok = true });
}

/// `{"location": "/abs/dir", "profile":null, "model":null, "thinking":null}` → session info. The location is normalized to
/// its git root.
fn createSession(s: *Server, c: *Ctx) !void {
    const body = try c.bodyJson(struct {
        location: []const u8,
        profile: ?[]const u8 = null,
        model: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        environment: ?core.config.Environment = null,
    });
    if (body.thinking) |level| if (!proto.thinking.validSelection(level)) return c.fail(.bad_request, "invalid thinking level");
    const location = core.location.resolve(c.arena, c.io, body.location) catch |err| switch (err) {
        error.RelativeLocation => return c.fail(.bad_request, "location must be an absolute path"),
        else => |e| return e,
    };
    const info = try s.runtime.createSessionWithOptionsOwned(c.arena, location, .{
        .profile = body.profile,
        .model = body.model,
        .thinking = body.thinking,
        .environment = body.environment,
    });
    try c.json(.ok, info);
}

/// `{"text": "…", "delivery": "queue"|"steer"}` → `{"inboxId": "msg_…"}`.
/// A receipt, not the result: progress arrives on `/event`.
fn prompt(s: *Server, c: *Ctx, session_id: []const u8) !void {
    const body = try c.bodyJson(struct {
        text: []const u8,
        delivery: core.inbox.Delivery = .queue,
        images: []const proto.attachment.Image = &.{},
    });
    const inbox_id = s.runtime.promptWithImages(session_id, body.text, body.delivery, body.images) catch |err| switch (err) {
        error.SessionNotFound => return c.fail(.not_found, "session not found"),
        else => |e| return e,
    };
    try c.json(.ok, .{ .inboxId = inbox_id.slice() });
}

/// `{"name": "review", "arguments": "…", "delivery", "images"}` →
/// `{"inboxId": "msg_…"}`. Expands the prompt template `name` for the
/// session's location and admits it like `/prompt`.
fn command(s: *Server, c: *Ctx, session_id: []const u8) !void {
    const body = try c.bodyJson(struct {
        name: []const u8,
        arguments: []const u8 = "",
        delivery: core.inbox.Delivery = .queue,
        images: []const proto.attachment.Image = &.{},
    });
    var problem: plugin.command.Problem = .{};
    const inbox_id = s.runtime.command(session_id, body.name, body.arguments, body.delivery, body.images, &problem) catch |err| switch (err) {
        error.SessionNotFound => return c.fail(.not_found, "session not found"),
        error.CommandNotFound => return c.fail(.not_found, "command not found"),
        // What the command's source said went wrong.
        error.CommandFailed => return c.fail(.bad_gateway, problem.text()),
        else => |e| return e,
    };
    try c.json(.ok, .{ .inboxId = inbox_id.slice() });
}

fn health(s: *Server, c: *Ctx) !void {
    try c.json(.ok, .{ .version = s.version, .pid = @as(i64, @intCast(std.c.getpid())) });
}

/// SSE feed of every bus event. `server.connected` goes first, to this
/// connection only. Ends when the client goes away or falls behind.
fn events(s: *Server, c: *Ctx) !void {
    const sub = try s.bus.subscribe();
    _ = s.event_listeners.fetchAdd(1, .acq_rel);
    defer {
        s.bus.unsubscribe(sub);
        if (s.event_listeners.fetchSub(1, .acq_rel) == 1) s.runtime.disconnectPermissions();
    }

    var buf: [8192]u8 = undefined;
    var body = try c.stream(&buf, "text/event-stream");
    const w = &body.writer;

    var hello: std.Io.Writer.Allocating = .init(c.arena);
    const env: proto.Envelope = .{
        .seq = 0,
        .type = proto.event.types.server_connected,
        .time = std.Io.Clock.real.now(c.io).toMilliseconds(),
        .data = "{}",
    };
    try env.write(&hello.writer);
    try proto.sse.writeFrame(w, null, hello.written());
    try flush(&body);

    // SSE is one-way. Waiting only for a bus frame cannot notice FIN until
    // the next write (normally the 15s heartbeat), leaving approvals pending
    // after the last answerer has gone away. Peek on the request socket in a
    // separate task: EOF, reset, or unexpected input all end this feed. Peek
    // does not consume anything from the HTTP connection reader.
    var disconnected: std.Io.Event = .unset;
    var monitor: std.Io.Group = .init;
    try monitor.concurrent(c.io, watchDisconnect, .{ c.req.server.reader.in, c.io, &disconnected });
    defer monitor.cancel(c.io);

    while (true) {
        const Next = union(enum) {
            frame: std.Io.Cancelable!?*core.bus.Frame,
            disconnect: std.Io.Cancelable!void,
        };
        var storage: [2]Next = undefined;
        var select: std.Io.Select(Next) = .init(c.io, &storage);
        defer while (select.cancel()) |leftover| switch (leftover) {
            .frame => |result| if (result catch null) |frame| frame.release(s.gpa),
            .disconnect => {},
        };
        try select.concurrent(.frame, core.bus.Subscriber.next, .{ sub, c.io });
        try select.concurrent(.disconnect, std.Io.Event.wait, .{ &disconnected, c.io });
        switch (try select.await()) {
            .disconnect => |result| {
                try result;
                // The listener cleanup will deny outstanding asks if this
                // was the last feed, without waiting for a heartbeat.
                return;
            },
            .frame => |result| {
                const frame = (try result) orelse break;
                defer frame.release(s.gpa);
                try proto.sse.writeFrame(w, null, frame.bytes);
                try flush(&body);
            },
        }
    }
    // Queue closed: this subscriber overflowed. Ending the response tells the
    // client to reconnect and resync.
    body.end() catch {};
}

fn watchDisconnect(reader: *std.Io.Reader, io: std.Io, disconnected: *std.Io.Event) std.Io.Cancelable!void {
    // A GET /event has no request body. Any readable byte is an invalid
    // pipelined request; EOF is the usual client disconnect. Neither should
    // keep an approval answerer registered.
    _ = reader.peek(1) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        disconnected.set(io);
        return;
    };
    disconnected.set(io);
}

/// `BodyWriter.flush` only flushes the connection, not the body buffer.
fn flush(body: *std.http.BodyWriter) !void {
    try body.writer.flush();
    try body.flush();
}

fn decoded(arena: std.mem.Allocator, segment: []const u8) ![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, segment));
}
