//! Atomic session metadata and inbox mutations. Returned values are owned by
//! the caller's arena, never borrowed from a deletable session.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const Info = @import("session.zig").Info;
const config = @import("config.zig");
const types = @import("proto").event.types;

pub const Update = struct {
    model: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// A thinking level name, or `auto` to drop the selection.
    thinking: ?[]const u8 = null,
};

pub fn updateSession(rt: *Runtime, arena: std.mem.Allocator, id: []const u8, change: Update) !Info {
    if (change.model == null and change.title == null and change.thinking == null) return error.InvalidPatch;
    if (change.thinking) |level| if (!@import("proto").thinking.validSelection(level)) return error.InvalidPatch;
    if (change.model) |model| {
        if (model.len == 0 or config.splitModel(model) == null) return error.InvalidPatch;
        for (model) |ch| if (std.ascii.isWhitespace(ch) or ch < 0x20 or ch == 0x7f) return error.InvalidPatch;
    }
    if (change.title) |title| {
        if (title.len > 200 or std.mem.trim(u8, title, " \t\r\n").len == 0 or !std.unicode.utf8ValidateSlice(title)) return error.InvalidPatch;
    }
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(id) orelse return error.SessionNotFound;
    if (entry.stopping) return error.SessionBusy;
    // Allocate the response and replacement selector before committing to disk.
    const new_model = if (change.model) |model| try rt.gpa.dupe(u8, model) else null;
    errdefer if (new_model) |v| rt.gpa.free(v);
    const info = entry.session.info;
    const owned: Info = .{
        .id = try arena.dupe(u8, info.id),
        .location = try arena.dupe(u8, info.location),
        .created = info.created,
        .title = if (change.title) |title| try arena.dupe(u8, title) else if (info.title) |title| try arena.dupe(u8, title) else null,
        .forkedFrom = if (info.forkedFrom) |v| try arena.dupe(u8, v) else null,
        .forkedAt = if (info.forkedAt) |v| try arena.dupe(u8, v) else null,
    };
    try entry.session.update(change.model, change.title, change.thinking);
    // New sessions start from the last pick.
    if (change.model != null or change.thinking != null) @import("runtime_model.zig").remember(rt, change.model, change.thinking);
    if (new_model) |model| {
        if (entry.overrides.model) |old| rt.gpa.free(old);
        entry.overrides.model = model;
    }
    rt.bus.publishValue(types.session_updated, info.id, info.location, .{ .session = entry.session.info, .model = entry.overrides.model, .thinking = entry.session.metadata.thinking }) catch {};
    return owned;
}

pub fn removeInboxItem(rt: *Runtime, session_id: []const u8, item_id: []const u8) !void {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(session_id) orelse return error.SessionNotFound;
    if (entry.stopping) return error.SessionBusy;
    try entry.inbox.remove(item_id);
    rt.publishInbox(entry);
}

pub fn removeInboxItemOwned(rt: *Runtime, arena: std.mem.Allocator, session_id: []const u8, item_id: []const u8) !@import("inbox.zig").Item {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(session_id) orelse return error.SessionNotFound;
    if (entry.stopping) return error.SessionBusy;
    const item = try entry.inbox.removeOwned(arena, item_id);
    rt.publishInbox(entry);
    return item;
}
