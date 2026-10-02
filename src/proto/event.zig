//! The event envelope. One shape everywhere: the SSE feed, `zeta run --json`,
//! and (later) extension notifications.
//!
//! `{"seq":812,"type":"message.part.delta","session":"ses_…","location":"/p","time":1790000000000,"data":{…}}`

const std = @import("std");

pub const Envelope = struct {
    seq: u64,
    type: []const u8,
    session: ?[]const u8 = null,
    location: ?[]const u8 = null,
    time: i64,
    /// Already-encoded JSON value.
    data: []const u8 = "{}",

    pub fn write(e: Envelope, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("seq");
        try s.write(e.seq);
        try s.objectField("type");
        try s.write(e.type);
        if (e.session) |v| {
            try s.objectField("session");
            try s.write(v);
        }
        if (e.location) |v| {
            try s.objectField("location");
            try s.write(v);
        }
        try s.objectField("time");
        try s.write(e.time);
        try s.objectField("data");
        try s.beginWriteRaw();
        try w.writeAll(e.data);
        s.endWriteRaw();
        try s.endObject();
    }
};

pub const types = struct {
    pub const server_connected = "server.connected";
    pub const server_heartbeat = "server.heartbeat";
    pub const session_created = "session.created";
    pub const session_updated = "session.updated";
    pub const session_moved = "session.moved";
    pub const session_deleted = "session.deleted";
    pub const session_idle = "session.idle";
    pub const session_inbox_updated = "session.inbox.updated";
    pub const session_error = "session.error";
    /// A hook refused a prompt before it joined the conversation; it left
    /// the inbox: `{inboxId, reason}`.
    pub const prompt_blocked = "prompt.blocked";
    /// Compaction began (`{reason: "manual" | "threshold"}`), ended with
    /// the summary logged (`{reason, messageId, tokensBefore}`), or failed
    /// (`{reason, error}`).
    pub const compaction_start = "compaction.start";
    pub const compaction_end = "compaction.end";
    pub const compaction_failed = "compaction.failed";
    pub const agent_start = "agent.start";
    pub const agent_end = "agent.end";
    pub const turn_start = "turn.start";
    pub const turn_end = "turn.end";
    pub const message_start = "message.start";
    pub const message_part_delta = "message.part.delta";
    pub const message_end = "message.end";
    pub const message_cancelled = "message.cancelled";
    /// A reply failed before streaming anything and will be requested again:
    /// `{messageId, attempt, maxAttempts, delayMs, errorMessage}`.
    pub const message_retry = "message.retry";
    pub const tool_execution_start = "tool.execution.start";
    pub const tool_execution_update = "tool.execution.update";
    pub const tool_execution_end = "tool.execution.end";
    /// A plugin asks the user (`{id, session, source, message, kind,
    /// expiresAt}` plus the kind's fields, see `docs/protocol.md`);
    /// answered with `POST /questions/:id/reply`. Then `{id, action}` once
    /// answered, expired or withdrawn.
    pub const question_asked = "question.asked";
    pub const question_resolved = "question.resolved";
    /// A plugin tells the user something: `{source, message, level}`.
    pub const plugin_notice = "plugin.notice";
};

/// Decoded form, for clients. `data` stays raw JSON.
pub const Decoded = struct {
    seq: u64,
    type: []const u8,
    session: ?[]const u8 = null,
    location: ?[]const u8 = null,
    time: i64,
    data: std.json.Value,

    pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Decoded {
        return std.json.parseFromSliceLeaky(Decoded, arena, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

test "envelope encodes raw data and omits null fields" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const e: Envelope = .{ .seq = 1, .type = types.server_connected, .time = 5, .data = "{\"a\":[1]}" };
    try e.write(&out.writer);
    try std.testing.expectEqualStrings(
        \\{"seq":1,"type":"server.connected","time":5,"data":{"a":[1]}}
    , out.written());

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = try Decoded.parse(arena.allocator(), out.written());
    try std.testing.expectEqual(@as(u64, 1), d.seq);
    try std.testing.expectEqual(@as(?[]const u8, null), d.session);
    try std.testing.expectEqual(@as(i64, 1), d.data.object.get("a").?.array.items[0].integer);
}
