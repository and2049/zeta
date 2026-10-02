//! Synchronous, typed session commands. Results and all nested strings belong to `arena`.
const std = @import("std");
const proto = @import("proto");
const Client = @import("Client.zig");
const Allocator = std.mem.Allocator;

pub const Info = struct { id: []const u8, location: []const u8, created: i64, title: ?[]const u8 = null, forkedFrom: ?[]const u8 = null, forkedAt: ?[]const u8 = null };
pub const Options = struct {
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Thinking level selection: a level name, or null for the default.
    thinking: ?[]const u8 = null,
    environment: ?struct { profile: ?[]const u8 = null, model: ?[]const u8 = null } = null,
};
pub const Inbox = struct { id: []const u8, text: []const u8, delivery: enum { queue, steer }, images: []const proto.attachment.Image = &.{} };
pub const Snapshot = struct {
    revision: u64,
    info: Info,
    options: Options,
    running: bool,
    inbox: []const Inbox,
    messages: []const proto.Message,
    inflight: ?proto.Message,
    nextBefore: ?[]const u8,
};
pub const Page = struct { messages: []const proto.Message, nextBefore: ?[]const u8 };
pub const Receipt = struct { inboxId: []const u8 };
pub const Delivery = enum { queue, steer };

fn result(comptime T: type, arena: Allocator, response: Client.Response) !T {
    try check(response);
    return std.json.parseFromSliceLeaky(T, arena, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}
/// Only recognize explicit server codes/messages. Never surface arbitrary
/// response text (which may contain user input or provider details).
pub fn check(response: Client.Response) !void {
    if (response.ok()) return;
    const parsed = std.json.parseFromSlice(struct { @"error": []const u8 }, std.heap.page_allocator, response.body, .{ .ignore_unknown_fields = true }) catch null;
    defer if (parsed) |value| value.deinit();
    const code = if (parsed) |value| value.value.@"error" else "";
    switch (response.status) {
        .unauthorized => return error.Unauthorized,
        .payload_too_large => return error.RequestTooLarge,
        .not_found => {
            if (eq(code, "session not found") or eq(code, "SessionNotFound")) return error.SessionNotFound;
            if (eq(code, "inbox item not found") or eq(code, "InboxItemNotFound")) return error.InboxItemNotFound;
            if (eq(code, "command not found")) return error.CommandNotFound;
            if (eq(code, "directory not found")) return error.NotFound;
        },
        .conflict => {
            if (eq(code, "inbox item already being processed") or eq(code, "InboxItemBusy")) return error.InboxItemBusy;
            if (eq(code, "SessionBusy")) return error.SessionBusy;
        },
        .bad_request => {
            if (eq(code, "ModelDoesNotSupportImages")) return error.ModelDoesNotSupportImages;
            if (eq(code, "InvalidImageMime")) return error.InvalidImageMime;
            if (eq(code, "InvalidImageData")) return error.InvalidImageData;
            if (eq(code, "invalid model, title or thinking level") or eq(code, "InvalidPatch")) return error.InvalidPatch;
        },
        else => {},
    }
    return error.HttpFailure;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn path(arena: Allocator, id: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "/sessions/{s}{s}", .{ id, suffix });
}
pub fn list(c: *Client, a: Allocator, location: ?[]const u8) ![]const Info {
    const p = if (location) |loc| try std.fmt.allocPrint(a, "/sessions?location={s}", .{try encode(a, loc)}) else "/sessions";
    return result([]const Info, a, try c.get(a, p));
}
pub fn create(c: *Client, a: Allocator, location: []const u8, opts: Options) !Info {
    return result(Info, a, try c.postJson(a, "/sessions", .{ .location = location, .profile = opts.profile, .model = opts.model, .thinking = opts.thinking, .environment = opts.environment }));
}
pub fn get(c: *Client, a: Allocator, id: []const u8) !Snapshot {
    const response = try c.get(a, try path(a, id, ""));
    try check(response);
    return decodeSnapshot(a, response.body);
}
pub fn page(c: *Client, a: Allocator, id: []const u8, before: ?[]const u8, limit: usize) !Page {
    if (limit == 0 or limit > 200) return error.InvalidLimit;
    const p = if (before) |cursor| try std.fmt.allocPrint(a, "{s}?before={s}&limit={d}", .{ try path(a, id, "/messages"), try encode(a, cursor), limit }) else try std.fmt.allocPrint(a, "{s}?limit={d}", .{ try path(a, id, "/messages"), limit });
    const response = try c.get(a, p);
    try check(response);
    const raw = try std.json.parseFromSliceLeaky(struct { messages: []const std.json.Value, nextBefore: ?[]const u8 }, a, response.body, .{ .ignore_unknown_fields = true });
    const messages = try a.alloc(proto.Message, raw.messages.len);
    for (raw.messages, messages) |value, *m| m.* = try proto.Message.parse(a, value);
    return .{ .messages = messages, .nextBefore = raw.nextBefore };
}

pub fn decodeSnapshot(a: Allocator, bytes: []const u8) !Snapshot {
    const raw = try std.json.parseFromSliceLeaky(struct {
        revision: u64,
        info: Info,
        options: Options,
        running: bool,
        inbox: []const Inbox,
        messages: []const std.json.Value,
        inflight: ?std.json.Value,
        nextBefore: ?[]const u8,
    }, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const messages = try a.alloc(proto.Message, raw.messages.len);
    for (raw.messages, messages) |value, *m| m.* = try proto.Message.parse(a, value);
    return .{
        .revision = raw.revision,
        .info = raw.info,
        .options = raw.options,
        .running = raw.running,
        .inbox = raw.inbox,
        .messages = messages,
        .inflight = if (raw.inflight) |v| try proto.Message.parse(a, v) else null,
        .nextBefore = raw.nextBefore,
    };
}
/// A new session copied from `id` up to and including `from` (the latest
/// message when null).
pub fn fork(c: *Client, a: Allocator, id: []const u8, from: ?[]const u8) !Info {
    return result(Info, a, try c.postJson(a, try std.fmt.allocPrint(a, "/sessions/{s}/fork", .{try encode(a, id)}), .{ .fromMessageId = from }));
}

/// Queues a compaction of the session's history, with optional instructions.
pub fn compact(c: *Client, a: Allocator, id: []const u8, instructions: []const u8) !Receipt {
    return result(Receipt, a, try c.postJson(a, try std.fmt.allocPrint(a, "/sessions/{s}/compact", .{try encode(a, id)}), .{ .instructions = instructions }));
}

pub fn prompt(c: *Client, a: Allocator, id: []const u8, text: []const u8, delivery: Delivery) !Receipt {
    return promptWithImages(c, a, id, text, delivery, &.{});
}
/// Image payloads are checked before transmission and copied into `a`.
pub fn promptWithImages(c: *Client, a: Allocator, id: []const u8, text: []const u8, delivery: Delivery, images: []const proto.attachment.Image) !Receipt {
    const checked = try a.alloc(proto.attachment.Image, images.len);
    for (images, checked) |image, *dest| dest.* = try proto.attachment.Image.init(a, image.mimeType, image.data);
    return result(Receipt, a, try c.postJson(a, try path(a, id, "/prompt"), .{ .text = text, .delivery = delivery, .images = checked }));
}
pub const Undone = struct { messageId: []const u8, files: []const struct { path: []const u8, restored: bool } };
pub const Moved = struct { moved: bool, location: []const u8 };
pub fn move(c: *Client, a: Allocator, id: []const u8, directory: []const u8) !Moved {
    return result(Moved, a, try c.postJson(a, try path(a, id, "/move"), .{ .directory = directory }));
}
/// Null when the session has no file changes left to undo.
pub fn undo(c: *Client, a: Allocator, id: []const u8) !?Undone {
    const response = try c.postJson(a, try path(a, id, "/undo"), .{});
    if (response.status == .not_found and std.mem.indexOf(u8, response.body, "nothing to undo") != null) return null;
    return try result(Undone, a, response);
}
/// One line for a status bar or terminal about what `undo` did.
pub fn undoSummary(buf: []u8, done: ?Undone) []const u8 {
    const d = done orelse return "Nothing to undo.";
    var w: std.Io.Writer = .fixed(buf);
    var restored: usize = 0;
    for (d.files) |f| restored += @intFromBool(f.restored);
    w.print("Undid {d} of {d} file change{s}", .{ restored, d.files.len, if (d.files.len == 1) "" else "s" }) catch return buf[0..w.end];
    for (d.files) |f| if (!f.restored) w.print("; {s} changed since, left as is", .{f.path}) catch return buf[0..w.end];
    w.writeByte('.') catch {};
    return buf[0..w.end];
}
pub fn abort(c: *Client, a: Allocator, id: []const u8) !void {
    _ = try result(struct { ok: bool }, a, try c.postJson(a, try path(a, id, "/abort"), .{}));
}
pub fn remove(c: *Client, a: Allocator, id: []const u8) !void {
    _ = try result(struct { ok: bool }, a, try c.delete(a, try path(a, id, "")));
}
pub fn removeInbox(c: *Client, a: Allocator, id: []const u8, inbox_id: []const u8) !void {
    _ = try removeInboxItem(c, a, id, inbox_id);
}
/// Returns the removed prompt with its images, owned by `a`.
pub fn removeInboxItem(c: *Client, a: Allocator, id: []const u8, inbox_id: []const u8) !Inbox {
    const receipt = try result(struct { ok: bool, item: Inbox }, a, try c.delete(a, try std.fmt.allocPrint(a, "/sessions/{s}/inbox/{s}", .{ id, inbox_id })));
    return receipt.item;
}
/// Request asynchronous title generation after the first user turn is saved.
pub fn generateTitle(c: *Client, a: Allocator, id: []const u8) !void {
    _ = try result(struct { ok: bool }, a, try c.postJson(a, try path(a, id, "/title"), .{}));
}
pub fn update(c: *Client, a: Allocator, id: []const u8, title: ?[]const u8, model: ?[]const u8) !Info {
    if (title == null and model == null) return error.EmptyPatch;
    const p = try path(a, id, "");
    const response = if (title) |t| if (model) |m|
        try c.patchJson(a, p, .{ .title = t, .model = m })
    else
        try c.patchJson(a, p, .{ .title = t }) else try c.patchJson(a, p, .{ .model = model.? });
    return result(Info, a, response);
}
/// Sets the session's thinking level (a level name, or `auto` for the
/// configured default) for its next run.
pub fn setThinking(c: *Client, a: Allocator, id: []const u8, level: []const u8) !Info {
    return result(Info, a, try c.patchJson(a, try path(a, id, ""), .{ .thinking = level }));
}
pub fn config(c: *Client, a: Allocator, id: []const u8) !std.json.Value {
    return resource(c, a, "config", id);
}
pub fn models(c: *Client, a: Allocator, id: []const u8) !std.json.Value {
    return resource(c, a, "models", id);
}
pub fn registry(c: *Client, a: Allocator, id: []const u8) !std.json.Value {
    return resource(c, a, "registry", id);
}
pub const ReloadFailure = struct { plugin: []const u8, message: []const u8 };
/// Rebuilds plugins loaded from outside the binary for the user layer and
/// `location`; the plugins listed kept their previous version.
pub fn reload(c: *Client, a: Allocator, location: ?[]const u8) ![]const ReloadFailure {
    const body = try result(struct { failures: []const ReloadFailure }, a, try c.postJson(a, "/registry/reload", .{ .location = location }));
    return body.failures;
}
fn resource(c: *Client, a: Allocator, kind: []const u8, id: []const u8) !std.json.Value {
    return result(std.json.Value, a, try c.get(a, try std.fmt.allocPrint(a, "/{s}?session={s}", .{ kind, try encode(a, id) })));
}

pub fn encode(a: Allocator, raw: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    errdefer w.deinit();
    try (std.Uri.Component{ .raw = raw }).formatEscaped(&w.writer);
    return w.toOwnedSlice();
}

test "snapshot decoder retains image blocks and changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try decodeSnapshot(arena.allocator(),
        \\{"revision":1,"info":{"id":"s","location":"/a","created":1},"options":{},"running":false,"inbox":[],"messages":[{"id":"m","role":"user","content":[{"type":"image","mimeType":"image/png","data":"YWJj"}],"timestamp":1,"changes":[{"path":"a","before":"x","after":"y"}]}],"inflight":null,"nextBefore":null}
    );
    try std.testing.expectEqualStrings("YWJj", v.messages[0].content[0].image.data);
    try std.testing.expectEqualStrings("y", v.messages[0].changes[0].after);
}

test {
    std.testing.refAllDecls(@This());
}

test "empty session patch is rejected before transport" {
    var fake: Client = undefined;
    try std.testing.expectError(error.EmptyPatch, update(&fake, std.testing.allocator, "s", null, null));
}

test "typed HTTP failures use status and recognized error codes" {
    const samples = .{
        .{ .status = std.http.Status.not_found, .body = "{\"error\":\"SessionNotFound\"}", .expected = error.SessionNotFound },
        .{ .status = std.http.Status.not_found, .body = "{\"error\":\"inbox item not found\"}", .expected = error.InboxItemNotFound },
        .{ .status = std.http.Status.conflict, .body = "{\"error\":\"SessionBusy\"}", .expected = error.SessionBusy },
        .{ .status = std.http.Status.conflict, .body = "{\"error\":\"inbox item already being processed\"}", .expected = error.InboxItemBusy },
        .{ .status = std.http.Status.bad_request, .body = "{\"error\":\"ModelDoesNotSupportImages\"}", .expected = error.ModelDoesNotSupportImages },
        .{ .status = std.http.Status.bad_request, .body = "{\"error\":\"invalid model, title or thinking level\"}", .expected = error.InvalidPatch },
        .{ .status = std.http.Status.payload_too_large, .body = "not json", .expected = error.RequestTooLarge },
        .{ .status = std.http.Status.unauthorized, .body = "{\"error\":\"unauthorized\"}", .expected = error.Unauthorized },
        .{ .status = std.http.Status.internal_server_error, .body = "{\"error\":\"api-key-secret\"}", .expected = error.HttpFailure },
    };
    inline for (samples) |sample| try std.testing.expectError(sample.expected, check(.{ .status = sample.status, .body = @constCast(sample.body) }));
    try check(.{ .status = .ok, .body = @constCast("") });
}
