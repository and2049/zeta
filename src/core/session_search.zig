//! Finding sessions by text, and a session as portable JSONL.
const std = @import("std");
const proto = @import("proto");
const Session = @import("session.zig").Session;
const Runtime = @import("Runtime.zig");
const Allocator = std.mem.Allocator;

/// Whether the session's title or the text of a user or assistant message
/// contains `query`, ignoring ASCII case.
pub fn matches(s: *Session, query: []const u8) bool {
    if (s.info.title) |title| if (std.ascii.indexOfIgnoreCase(title, query) != null) return true;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (s.messages.items) |m| {
        if (m.role == .tool_result) continue;
        for (m.content) |c| if (c == .text and std.ascii.indexOfIgnoreCase(c.text, query) != null) return true;
    }
    return false;
}

/// The session as JSONL, in `arena`: a `session` header line, then one
/// `message` line per message, oldest first.
pub fn exportJsonl(rt: *Runtime, arena: Allocator, id: []const u8) ![]const u8 {
    var snapshot = blk: {
        rt.mutex.lockUncancelable(rt.io);
        defer rt.mutex.unlock(rt.io);
        const entry = rt.sessions.get(id) orelse return error.SessionNotFound;
        break :blk try entry.session.snapshot(rt.gpa);
    };
    defer snapshot.deinit();
    var out: std.Io.Writer.Allocating = .init(arena);
    const info = snapshot.info;
    try std.json.Stringify.value(.{
        .type = "session",
        .version = @import("session.zig").format_version,
        .id = info.id,
        .location = info.location,
        .timestamp = info.created,
        .title = info.title,
        .forkedFrom = info.forkedFrom,
        .forkedAt = info.forkedAt,
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');
    for (snapshot.messages) |m| {
        try std.json.Stringify.value(.{ .type = "message", .message = m }, .{ .emit_null_optional_fields = false }, &out.writer);
        try out.writer.writeByte('\n');
    }
    return out.written();
}
