//! What `zeta run` has shown of one run, so a reconnect can print only what
//! it missed. Plain mode prints assistant text; each reply is printed once,
//! whether it arrived as deltas, as a completed message, or in a snapshot.
const std = @import("std");
const proto = @import("proto");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Message = proto.Message;

pub const Outcome = enum { ok, failed };

pub const Follower = struct {
    gpa: Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    /// `--json` prints raw events instead of text.
    json: bool,
    /// The run's user message; the run's replies follow it in history.
    prompt_id: []const u8,
    /// The assistant message being printed (gpa-owned) and how many of its
    /// text bytes are out.
    current: ?[]u8 = null,
    printed: usize = 0,
    /// Replies that ended and were printed in full (gpa-owned ids).
    done: std.ArrayList([]u8) = .empty,
    wrote_text: bool = false,
    outcome: Outcome = .ok,
    /// How the last reply ended. A run that ends on `tool_use` had a tool
    /// denied; one with no reply at all was interrupted.
    last_stop: ?proto.message.StopReason = null,
    /// Text of the last failed tool result (gpa-owned).
    tool_error: ?[]u8 = null,

    pub fn deinit(f: *Follower) void {
        if (f.current) |id| f.gpa.free(id);
        if (f.tool_error) |text| f.gpa.free(text);
        for (f.done.items) |id| f.gpa.free(id);
        f.done.deinit(f.gpa);
    }

    pub fn delta(f: *Follower, message_id: []const u8, text: []const u8) !void {
        try f.select(message_id);
        try f.write(text);
    }

    /// A completed message, from `message.end` or a snapshot.
    pub fn ended(f: *Follower, m: Message) !void {
        switch (m.role) {
            .assistant => {
                if (f.isDone(m.id)) return;
                try f.select(m.id);
                try f.catchUp(m);
                try f.done.append(f.gpa, try f.gpa.dupe(u8, m.id));
                f.last_stop = m.stopReason;
                if (m.stopReason == .@"error" or m.stopReason == .aborted) {
                    f.outcome = .failed;
                    try f.stderr.print("error: {s}\n", .{m.errorMessage orelse @tagName(m.stopReason.?)});
                    try f.stderr.flush();
                }
            },
            .tool_result => if (m.isError) {
                if (f.tool_error) |old| f.gpa.free(old);
                f.tool_error = try f.gpa.dupe(u8, if (m.content.len > 0 and m.content[0] == .text) m.content[0].text else "tool failed");
            },
            else => {},
        }
    }

    /// Prints what a disconnect hid: replies after the last one shown, then
    /// the rest of the streaming draft.
    pub fn reconcile(f: *Follower, messages: []const Message, inflight: ?Message) !void {
        const start = for (messages, 0..) |m, i| {
            if (std.mem.eql(u8, m.id, f.prompt_id)) break i + 1;
        } else 0;
        for (messages[start..]) |m| try f.ended(m);
        if (inflight) |draft| {
            try f.select(draft.id);
            try f.catchUp(draft);
        }
    }

    /// The run is over: settle the outcome and finish the output.
    pub fn finish(f: *Follower) !Outcome {
        if (f.outcome == .ok) {
            const reason: ?[]const u8 = if (f.last_stop) |stop| switch (stop) {
                .tool_use => f.tool_error orelse "a tool call was not completed",
                else => null,
            } else "the run was interrupted";
            if (reason) |why| {
                f.outcome = .failed;
                try f.stderr.print("error: the run stopped before a final reply: {s}\n", .{why});
                try f.stderr.flush();
            }
        }
        if (f.wrote_text) {
            try f.stdout.writeByte('\n');
            try f.stdout.flush();
        }
        return f.outcome;
    }

    fn isDone(f: *const Follower, id: []const u8) bool {
        for (f.done.items) |done| if (std.mem.eql(u8, done, id)) return true;
        return false;
    }

    fn select(f: *Follower, id: []const u8) !void {
        if (f.current) |current| if (std.mem.eql(u8, current, id)) return;
        const owned = try f.gpa.dupe(u8, id);
        if (f.current) |old| f.gpa.free(old);
        f.current = owned;
        f.printed = 0;
    }

    /// Prints the part of `m`'s text not yet shown.
    fn catchUp(f: *Follower, m: Message) !void {
        var offset: usize = 0;
        for (m.content) |part| {
            if (part != .text) continue;
            const text = part.text;
            if (offset + text.len > f.printed) try f.write(text[f.printed -| offset..]);
            offset += text.len;
        }
    }

    fn write(f: *Follower, text: []const u8) !void {
        f.printed += text.len;
        if (f.json or text.len == 0) return;
        try f.stdout.writeAll(text);
        try f.stdout.flush();
        f.wrote_text = true;
    }
};

test "reconcile prints only the unseen part of each reply" {
    const a = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(a);
    defer err.deinit();
    var f: Follower = .{ .gpa = a, .stdout = &out.writer, .stderr = &err.writer, .json = false, .prompt_id = "u1" };
    defer f.deinit();
    try f.delta("a1", "Hel");
    const history = [_]Message{
        .{ .id = "u0", .role = .user, .timestamp = 0, .content = &.{.{ .text = "older" }} },
        .{ .id = "a0", .role = .assistant, .timestamp = 0, .content = &.{.{ .text = "older reply" }}, .stopReason = .stop },
        .{ .id = "u1", .role = .user, .timestamp = 0, .content = &.{.{ .text = "prompt" }} },
        .{ .id = "a1", .role = .assistant, .timestamp = 0, .content = &.{ .{ .text = "Hello" }, .{ .tool_call = .{ .id = "c", .name = "read", .arguments = "{}" } } }, .stopReason = .tool_use },
        .{ .id = "t1", .role = .tool_result, .timestamp = 0, .content = &.{.{ .text = "ok" }}, .toolCallId = "c" },
        .{ .id = "a2", .role = .assistant, .timestamp = 0, .content = &.{.{ .text = " world" }}, .stopReason = .stop },
    };
    try f.reconcile(&history, .{ .id = "a3", .role = .assistant, .timestamp = 0, .content = &.{.{ .text = "!" }} });
    try f.delta("a3", "?");
    try f.ended(.{ .id = "a3", .role = .assistant, .timestamp = 0, .content = &.{.{ .text = "!?" }}, .stopReason = .stop });
    try std.testing.expectEqual(Outcome.ok, try f.finish());
    try std.testing.expectEqualStrings("Hello world!?\n", out.written());
}

test "a run that ends on tool calls failed; its denial is reported" {
    const a = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(a);
    defer err.deinit();
    var f: Follower = .{ .gpa = a, .stdout = &out.writer, .stderr = &err.writer, .json = false, .prompt_id = "u" };
    defer f.deinit();
    try f.ended(.{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{.{ .tool_call = .{ .id = "c", .name = "write", .arguments = "{}" } }}, .stopReason = .tool_use });
    try f.ended(.{ .id = "t", .role = .tool_result, .timestamp = 0, .content = &.{.{ .text = "Tool execution denied by permission policy." }}, .toolCallId = "c", .isError = true });
    try std.testing.expectEqual(Outcome.failed, try f.finish());
    try std.testing.expectEqualStrings("error: the run stopped before a final reply: Tool execution denied by permission policy.\n", err.written());
}
