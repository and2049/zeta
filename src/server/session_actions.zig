//! Session workflow endpoints; route dispatch is wired by the composition owner.
const std = @import("std");
const Server = @import("Server.zig");
const Ctx = @import("conn.zig").Ctx;

/// PATCH /sessions/:id with at least one of `model`, `title`, `thinking`
/// (a level name, or `auto` for the configured default).
pub fn patchSession(s: *Server, c: *Ctx, id: []const u8) !void {
    if (c.method != .PATCH) return c.fail(.method_not_allowed, "method not allowed");
    const bytes = try c.body();
    const value = std.json.parseFromSliceLeaky(std.json.Value, c.arena, bytes, .{}) catch return c.fail(.bad_request, "invalid session patch");
    if (value != .object or value.object.count() == 0) return c.fail(.bad_request, "model, title or thinking required");
    var update: @import("core").Runtime.Update = .{};
    for (value.object.keys(), value.object.values()) |key, item| {
        if (item != .string) return c.fail(.bad_request, "model, title and thinking must be strings");
        if (std.mem.eql(u8, key, "model")) {
            update.model = item.string;
        } else if (std.mem.eql(u8, key, "title")) {
            update.title = item.string;
        } else if (std.mem.eql(u8, key, "thinking")) {
            update.thinking = item.string;
        } else return c.fail(.bad_request, "unknown session patch field");
    }
    const info = s.runtime.updateSession(c.arena, id, update) catch |err| switch (err) {
        error.InvalidPatch => return c.fail(.bad_request, "invalid model, title or thinking level"),
        else => |e| return e,
    };
    return c.json(.ok, info);
}

/// DELETE /sessions/:id/inbox/:itemId.
pub fn deleteInboxItem(s: *Server, c: *Ctx, id: []const u8, item_id: []const u8) !void {
    if (c.method != .DELETE) return c.fail(.method_not_allowed, "method not allowed");
    const removed = s.runtime.removeInboxItemOwned(c.arena, id, item_id) catch |err| switch (err) {
        error.InboxItemBusy => return c.fail(.conflict, "inbox item already being processed"),
        error.InboxItemNotFound => return c.fail(.not_found, "inbox item not found"),
        else => |e| return e,
    };
    return c.json(.ok, .{ .ok = true, .item = removed });
}

/// POST /sessions/:id/title is a nonblocking generation receipt.
/// `{"instructions"?}` → `{"inboxId"}`: queues a compaction of the history.
pub fn compact(s: *Server, c: *Ctx, id: []const u8) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    const body = try c.bodyJson(struct { instructions: []const u8 = "" });
    const inbox_id = try s.runtime.compact(id, body.instructions);
    return c.json(.ok, .{ .inboxId = inbox_id.slice() });
}

/// `{"fromMessageId"?}` → the new session's info: a copy of this session
/// up to and including that message (the latest when omitted).
pub fn fork(s: *Server, c: *Ctx, id: []const u8) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    const body = try c.bodyJson(struct { fromMessageId: ?[]const u8 = null });
    return c.json(.ok, try s.runtime.fork(c.arena, id, body.fromMessageId));
}

/// Move an idle session to the project containing an absolute directory.
pub fn move(s: *Server, c: *Ctx, id: []const u8) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    const body = try c.bodyJson(struct { directory: []const u8 });
    const result = s.runtime.move(c.arena, id, body.directory) catch |err| switch (err) {
        error.RelativeLocation, error.NotDirectory => return c.fail(.bad_request, "invalid directory"),
        error.DirectoryNotFound => return c.fail(.not_found, "directory not found"),
        else => return err,
    };
    return c.json(.ok, result);
}

pub fn generateTitle(s: *Server, c: *Ctx, id: []const u8) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    s.runtime.requestTitle(id) catch |err| switch (err) {
        error.NoUserText => return c.fail(.bad_request, "session has no user text yet"),
        else => |e| return e,
    };
    return c.json(.ok, .{ .ok = true });
}
