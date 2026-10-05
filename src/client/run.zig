//! `zeta run`: one prompt, headless. Attaches to (or starts) the shared
//! server, creates a session for the current project (or continues one:
//! a given id, or the project's latest), sends the prompt and
//! streams the reply: plain text by default, event JSONL with `--json`.
//! If the event stream drops, it reconnects (never starting a server),
//! catches up from a session snapshot, and continues.

const std = @import("std");
const proto = @import("proto");
const platform = @import("platform");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const attach = @import("attach.zig");
const api = @import("session_api.zig");
const types = proto.event.types;
const questions = @import("questions.zig");
const question_prompt = @import("question_prompt.zig");
const Follower = @import("run_follow.zig").Follower;

pub const Options = struct {
    paths: platform.Paths,
    exe: []const u8,
    cwd: []const u8,
    text: []const u8,
    images: []const proto.attachment.Image = &.{},
    json: bool = false,
    /// Continue this session instead of creating one.
    session: ?[]const u8 = null,
    /// Continue the project's latest session, if it has one.
    latest: bool = false,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Thinking level for the session (a level name).
    thinking: ?[]const u8 = null,
    /// How to start the server if none answers (a standalone run's private
    /// one); the shared server by default.
    serve: []const []const u8 = &.{"serve"},
    log: ?[]const u8 = null,
    /// Caller ZETA_PROFILE/ZETA_MODEL, distinct from CLI overrides.
    environment: ?struct { model: ?[]const u8 = null, profile: ?[]const u8 = null } = null,
};

pub const Outcome = @import("run_follow.zig").Outcome;

const Opened = struct { id: []const u8, location: []const u8 };

/// The session to prompt: the one asked for, the project's latest, or a
/// new one. Null after saying why on stderr.
fn open(arena: Allocator, client: *Client, stderr: *Io.Writer, o: Options) !?Opened {
    const existing = if (o.session) |id| id else if (o.latest) blk: {
        const sessions = api.list(client, arena, o.cwd) catch |err| {
            try stderr.print("error: listing sessions: {s}\n", .{@errorName(err)});
            return null;
        };
        // Listed most recently active first.
        break :blk if (sessions.len > 0) sessions[0].id else null;
    } else null;
    if (existing) |id| {
        const snapshot = api.get(client, arena, id) catch |err| {
            try stderr.print("error: session {s}: {s}\n", .{ id, if (err == error.SessionNotFound) "not found" else @errorName(err) });
            return null;
        };
        // Overrides apply to the continued session from now on.
        if (o.model != null) _ = api.update(client, arena, id, null, o.model) catch |err| {
            try stderr.print("error: setting the model: {s}\n", .{@errorName(err)});
            return null;
        };
        if (o.thinking) |level| _ = api.setThinking(client, arena, id, level) catch |err| {
            try stderr.print("error: setting the thinking level: {s}\n", .{@errorName(err)});
            return null;
        };
        return .{ .id = snapshot.info.id, .location = snapshot.info.location };
    }
    const created = try client.postJson(arena, "/sessions", .{
        .location = o.cwd,
        .profile = o.profile,
        .model = o.model,
        .thinking = o.thinking,
        .environment = o.environment,
    });
    if (!created.ok()) {
        _ = try fail(stderr, "creating session", created);
        return null;
    }
    return try std.json.parseFromSliceLeaky(Opened, arena, created.body, .{ .ignore_unknown_fields = true });
}

/// How long to keep looking for the server after the event stream drops.
const reconnect_ms = 10_000;

pub fn run(gpa: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, o: Options) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ev_arena: std.heap.ArenaAllocator = .init(gpa);
    defer ev_arena.deinit();

    const server: attach.Options = .{ .paths = o.paths, .exe = o.exe, .serve = o.serve, .log = o.log };
    // Subscribe before prompting so no event is missed.
    var link: ?*Link = try Link.open(gpa, io, try attach.attach(gpa, arena, io, server), ev_arena.allocator());
    defer if (link) |l| l.close(gpa);

    const info = (try open(arena, &link.?.client, stderr, o)) orelse {
        try stderr.flush();
        return .failed;
    };
    const path = try std.fmt.allocPrint(arena, "/sessions/{s}/prompt", .{info.id});
    const sent = try link.?.client.postJson(arena, path, .{ .text = o.text, .images = o.images });
    if (!sent.ok()) return fail(stderr, "sending prompt", sent);
    const receipt = try std.json.parseFromSliceLeaky(api.Receipt, arena, sent.body, .{ .ignore_unknown_fields = true });

    var follower: Follower = .{ .gpa = gpa, .stdout = stdout, .stderr = stderr, .json = o.json, .prompt_id = receipt.inboxId };
    defer follower.deinit();
    // After a reconnect, events up to the snapshot's revision are in it.
    var skip_through: ?u64 = null;
    while (true) {
        _ = ev_arena.reset(.retain_capacity);
        const next = link.?.events.next(ev_arena.allocator()) catch |err| blk: {
            if (err == error.Canceled) return err;
            break :blk null;
        };
        const f = next orelse {
            link.?.close(gpa);
            link = null;
            const recovered = (try recover(gpa, io, arena, server, info.id, ev_arena.allocator())) orelse {
                try stderr.writeAll("error: lost the connection to the zeta server\n");
                try stderr.flush();
                return .failed;
            };
            link = recovered.link;
            skip_through = recovered.snapshot.revision;
            // Questions asked while disconnected cannot be answered here.
            _ = questions.declineOpen(&link.?.client, ev_arena.allocator(), info.location, info.id) catch 0;
            try follower.reconcile(recovered.snapshot.messages, recovered.snapshot.inflight);
            if (!recovered.snapshot.running) break;
            continue;
        };
        const e = f.event;
        if (skip_through) |revision| if (e.seq <= revision) continue;
        // Only this run's own questions: another client may answer the rest.
        if (std.mem.eql(u8, e.type, types.question_asked) and e.session != null and std.mem.eql(u8, e.session.?, info.id)) {
            try answerQuestion(ev_arena.allocator(), io, &link.?.client, stderr, e.data);
            continue;
        }
        if (std.mem.eql(u8, e.type, types.plugin_notice) and mine(e, info.id, info.location)) {
            const n = std.json.parseFromValueLeaky(struct { source: []const u8 = "", message: []const u8 = "", level: []const u8 = "info" }, ev_arena.allocator(), e.data, .{ .ignore_unknown_fields = true }) catch continue;
            try stderr.print("{s}{s}: {s}\n", .{ n.source, if (std.mem.eql(u8, n.level, "info")) "" else try std.fmt.allocPrint(ev_arena.allocator(), " ({s})", .{n.level}), n.message });
            try stderr.flush();
            continue;
        }
        if (e.session == null or !std.mem.eql(u8, e.session.?, info.id)) continue;

        if (o.json) {
            try stdout.print("{s}\n", .{f.raw});
            try stdout.flush();
        }
        if (std.mem.eql(u8, e.type, types.message_part_delta)) {
            if (textDelta(e.data)) |d| try follower.delta(d.id, d.text);
        } else if (std.mem.eql(u8, e.type, types.message_end)) {
            const value = if (e.data == .object) e.data.object.get("message") else null;
            if (value) |m| try follower.ended(try proto.Message.parse(ev_arena.allocator(), m));
        } else if (std.mem.eql(u8, e.type, types.prompt_blocked)) {
            const blocked = std.json.parseFromValueLeaky(struct { inboxId: []const u8, reason: []const u8 }, ev_arena.allocator(), e.data, .{ .ignore_unknown_fields = true }) catch continue;
            if (!std.mem.eql(u8, blocked.inboxId, receipt.inboxId)) continue;
            try stderr.print("error: prompt blocked: {s}\n", .{blocked.reason});
            try stderr.flush();
            return .failed;
        } else if (std.mem.eql(u8, e.type, types.session_error)) {
            const msg = if (e.data.object.get("error")) |v| if (v == .string) v.string else "?" else "?";
            try stderr.print("error: {s}\n", .{msg});
            try stderr.flush();
            return .failed;
        } else if (std.mem.eql(u8, e.type, types.agent_end)) {
            break;
        }
    }
    return follower.finish();
}

/// A plugin asked this run's user something: asked on the terminal, or
/// declined without one.
fn answerQuestion(a: Allocator, io: Io, client: *Client, stderr: *Io.Writer, data: std.json.Value) !void {
    const id = if (data == .object) if (data.object.get("id")) |v| if (v == .string) v.string else return else return else return;
    const q = questions.Question.parse(a, data) orelse return questions.answer(client, a, id, "decline", null) catch {};
    const reply = try question_prompt.ask(a, io, stderr, q);
    if (std.mem.eql(u8, reply.action, "decline") and !(Io.File.stdin().isTty(io) catch false)) {
        try stderr.print("{s} asked: {s} (declined: no terminal to answer on)\n", .{ q.source, q.message });
        try stderr.flush();
    }
    questions.answer(client, a, q.id, reply.action, reply.content) catch |err| {
        if (err == error.Canceled) return err;
        try stderr.print("answering a question failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
    };
}

/// A notice for this run: its session's, or its project's without one.
fn mine(e: proto.event.Decoded, session: []const u8, location: []const u8) bool {
    if (e.session) |s| return std.mem.eql(u8, s, session);
    const at = e.location orelse return false;
    return std.mem.eql(u8, at, location);
}

/// One server connection. Heap-allocated: the event stream points into
/// `client`'s transport.
const Link = struct {
    client: Client,
    events: *Client.EventStream,

    /// Connects and waits for `server.connected`. `d`'s strings must
    /// outlive the link.
    fn open(gpa: Allocator, io: Io, d: proto.Discovery, ev_arena: Allocator) !*Link {
        const l = try gpa.create(Link);
        errdefer gpa.destroy(l);
        l.client = try Client.init(gpa, io, d.url, d.password);
        errdefer l.client.deinit();
        l.events = try l.client.events();
        errdefer l.events.deinit(gpa);
        const first = (try l.events.next(ev_arena)) orelse return error.EventStreamClosed;
        if (!std.mem.eql(u8, first.event.type, types.server_connected)) return error.UnexpectedEvent;
        return l;
    }

    fn close(l: *Link, gpa: Allocator) void {
        l.events.deinit(gpa);
        l.client.deinit();
        gpa.destroy(l);
    }
};

/// Finds the server again (without starting one), subscribes, then takes a
/// snapshot, so events after the snapshot's revision are not missed.
fn recover(gpa: Allocator, io: Io, arena: Allocator, server: attach.Options, session: []const u8, ev_arena: Allocator) !?struct { link: *Link, snapshot: api.Snapshot } {
    const deadline = Io.Clock.awake.now(io).toMilliseconds() + reconnect_ms;
    while (Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        if (try attach.find(gpa, arena, io, server)) |d| {
            if (Link.open(gpa, io, d, ev_arena)) |link| {
                errdefer link.close(gpa);
                return .{ .link = link, .snapshot = try api.get(&link.client, arena, session) };
            } else |err| if (err == error.Canceled) return err;
        }
        try io.sleep(.fromMilliseconds(250), .awake);
    }
    return null;
}

fn textDelta(data: std.json.Value) ?struct { id: []const u8, text: []const u8 } {
    if (data != .object) return null;
    const kind = data.object.get("kind") orelse return null;
    const delta = data.object.get("delta") orelse return null;
    const id = data.object.get("messageId") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "text") or delta != .string or id != .string) return null;
    return .{ .id = id.string, .text = delta.string };
}

fn fail(stderr: *Io.Writer, what: []const u8, res: Client.Response) !Outcome {
    try stderr.print("error: {s}: HTTP {d} {s}\n", .{ what, @intFromEnum(res.status), res.body });
    try stderr.flush();
    return .failed;
}

test textDelta {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"messageId":"m","index":0,"kind":"text","delta":"hi"}
    , .{});
    try std.testing.expectEqualStrings("hi", textDelta(v).?.text);
    const thinking = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"messageId":"m","index":0,"kind":"thinking","delta":"hm"}
    , .{});
    try std.testing.expect(textDelta(thinking) == null);
}

test {
    _ = @import("run_follow.zig");
}
