//! Deep-copied display projection. State may reset its arena on reconnect;
//! App's message arena owns every string displayed until the next sync.
const std = @import("std");
const App = @import("App.zig");
const client = @import("client");
const proto = @import("proto");
const A = std.mem.Allocator;

pub fn sync(app: *App, state: *const client.state.State) !void {
    const snapshot = state.snapshot orelse return;
    app.messages.clearRetainingCapacity();
    app.pending.clearRetainingCapacity();
    _ = app.message_arena.reset(.retain_capacity);
    const a = app.message_arena.allocator();
    app.connected = true;
    app.running = snapshot.running;
    app.title = try a.dupe(u8, snapshot.info.title orelse "Untitled session");
    app.named = if (snapshot.info.title) |title| title.len > 0 else false;
    app.model = if (snapshot.options.model) |name| try a.dupe(u8, name) else app.model_owned orelse "";
    app.thinking = if (snapshot.options.thinking) |level| try a.dupe(u8, level) else "";
    app.usage_input = 0;
    app.usage_output = 0;
    app.cost = 0;
    app.last_context = null;
    // Match tool-result IDs across the loaded page and current inflight turn.
    var outstanding: std.StringHashMapUnmanaged(usize) = .empty;
    defer outstanding.deinit(a);
    var turn_start: ?i64 = null;
    for (snapshot.messages) |m| try add(app, a, m, &outstanding, false, &turn_start);
    if (snapshot.inflight) |m| try add(app, a, m, &outstanding, true, &turn_start);
    app.turn_started = if (snapshot.running) turn_start else null;
    // Idle with a turn still open: it was stopped before any final reply
    // (e.g. during a tool call).
    if (!snapshot.running and snapshot.inflight == null) if (turn_start) |started| if (snapshot.messages.len > 0) {
        const last = snapshot.messages[snapshot.messages.len - 1];
        if (last.role != .user) try app.messages.append(app.allocator, .{ .role = "turn_end", .text = "", .turn = .{
            .started = started,
            .ended = last.completedAt orelse last.timestamp,
            .outcome = .stopped,
        } });
    };
    app.activity = .working;
    app.activity_tool = "";
    if (app.compacting) app.activity = .compacting else if (app.messages.items.len > 0) {
        const last = app.messages.items[app.messages.items.len - 1];
        if (last.tool_running) {
            app.activity = .tool;
            app.activity_tool = last.tool_name orelse "";
        } else if (snapshot.inflight) |m| {
            if (m.content.len > 0 and m.content[m.content.len - 1] == .thinking) app.activity = .thinking;
        }
    }
    for (app.messages.items) |*m| if (m.tool_running) {
        m.tool_running = snapshot.running;
    };
    for (snapshot.inbox) |entry| try app.pending.append(app.allocator, .{
        .id = try a.dupe(u8, entry.id),
        .text = try a.dupe(u8, entry.text),
        .delivery = try a.dupe(u8, @tagName(entry.delivery)),
    });
    if (snapshot.pendingPermissions.len > 0) {
        const permission = snapshot.pendingPermissions[0];
        app.permission = .{ .id = try a.dupe(u8, permission.id), .action = try a.dupe(u8, permission.action), .pattern = try a.dupe(u8, permission.pattern), .expires_at = permission.expiresAt };
        if (app.overlay == .none) app.overlay = .permission;
    } else {
        app.permission = null;
        if (app.overlay == .permission) app.overlay = .none;
    }
    app.render_revision +%= 1;
}

/// `turn_start`: when the turn in progress began (its first typed message).
fn add(app: *App, a: A, m: proto.Message, outstanding: *std.StringHashMapUnmanaged(usize), inflight: bool, turn_start: *?i64) !void {
    if (m.role == .user and m.origin == null and turn_start.* == null) turn_start.* = m.timestamp;
    if (m.usage) |usage| {
        if (!inflight) {
            app.usage_input +|= usage.input +| usage.cacheRead;
            app.usage_output +|= usage.output;
            app.cost += usage.cost orelse 0;
            app.last_context = usage.input +| usage.cacheRead +| usage.cacheWrite +| usage.output;
        }
    }
    // A result folds into its call's entry.
    if (m.role == .tool_result) if (m.toolCallId) |id| if (outstanding.fetchRemove(id)) |match| {
        const call = &app.messages.items[match.value];
        call.tool_running = false;
        call.is_error = m.isError;
        call.changes = try cloneChanges(a, m.changes);
        var output: std.ArrayList(u8) = .empty;
        for (m.content) |part| switch (part) {
            .text => |s| try output.appendSlice(a, s),
            .image => try output.appendSlice(a, "[image]"),
            else => {},
        };
        call.output = try output.toOwnedSlice(a);
        return;
    };
    var text: std.ArrayList(u8) = .empty;
    var thinking: std.ArrayList(u8) = .empty;
    for (m.content) |part| switch (part) {
        .text => |s| {
            if (thinking.items.len > 0) try flush(app, a, m, &text, &thinking, false);
            try text.appendSlice(a, s);
        },
        .thinking => |s| {
            if (text.items.len > 0) try flush(app, a, m, &text, &thinking, false);
            try thinking.appendSlice(a, s.text);
        },
        .image => {
            if (thinking.items.len > 0) try flush(app, a, m, &text, &thinking, false);
            try text.appendSlice(a, "[image]");
        },
        .tool_call => |tool| {
            try flush(app, a, m, &text, &thinking, false);
            const index = app.messages.items.len;
            try app.messages.append(app.allocator, .{
                .role = "tool_call",
                .id = try a.dupe(u8, tool.id),
                .text = try a.dupe(u8, tool.arguments),
                .tool_name = try a.dupe(u8, tool.name),
                .tool_running = true,
            });
            try outstanding.put(a, app.messages.items[index].id.?, index);
        },
    };
    if (m.errorMessage) |error_text| {
        if (text.items.len > 0) try text.append(a, '\n');
        try text.appendSlice(a, "Error: ");
        try text.appendSlice(a, error_text);
    } else if (m.stopReason) |reason| if (reason == .@"error" or reason == .aborted) {
        if (text.items.len > 0) try text.append(a, '\n');
        try text.appendSlice(a, if (reason == .aborted) "Turn aborted" else "Assistant failed");
    };
    try flush(app, a, m, &text, &thinking, true);
    // A reply that ends the turn: say how long it took.
    if (m.role == .assistant and !inflight) if (m.stopReason) |reason| if (reason != .tool_use) {
        if (turn_start.*) |started| try app.messages.append(app.allocator, .{ .role = "turn_end", .text = "", .turn = .{
            .started = started,
            .ended = m.completedAt orelse m.timestamp,
            .outcome = switch (reason) {
                .aborted => .stopped,
                .@"error" => .failed,
                else => if (m.errorMessage != null) .failed else .done,
            },
        } });
        turn_start.* = null;
    };
}

fn flush(app: *App, a: A, m: proto.Message, text: *std.ArrayList(u8), thinking: *std.ArrayList(u8), final: bool) !void {
    if (text.items.len == 0 and thinking.items.len == 0 and !final) return;
    if (text.items.len == 0 and thinking.items.len == 0 and m.role == .assistant and m.changes.len == 0 and !m.isError) return;
    const changes = if (final) try cloneChanges(a, m.changes) else &.{};
    try app.messages.append(app.allocator, .{
        .id = try a.dupe(u8, m.id),
        .role = @tagName(m.role),
        .text = try text.toOwnedSlice(a),
        .thinking = try thinking.toOwnedSlice(a),
        .tool_name = if (m.toolName) |name| try a.dupe(u8, name) else null,
        .origin = if (m.origin) |origin| try a.dupe(u8, origin) else null,
        .tokens_before = m.tokensBefore,
        .is_error = m.isError or m.stopReason == .@"error",
        .changes = changes,
    });
}

fn cloneChanges(a: A, changes: []const proto.message.FileChange) ![]const proto.message.FileChange {
    const copied = try a.alloc(proto.message.FileChange, changes.len);
    for (changes, copied) |source, *target| target.* = .{
        .path = try a.dupe(u8, source.path),
        .before = try a.dupe(u8, source.before),
        .after = try a.dupe(u8, source.after),
        .truncated = source.truncated,
    };
    return copied;
}

test "projection deep copies display fields and preserves reasoning and tool arguments" {
    const a = std.testing.allocator;
    var app = App.init(a, "/tmp");
    defer app.deinit();
    var state = client.state.State.init(a);
    defer state.deinit();
    const title = try a.dupe(u8, "Session title");
    defer a.free(title);
    const arguments = try a.dupe(u8, "{\"path\":\"x\"}");
    defer a.free(arguments);
    const entries = [_]proto.Message{.{ .id = "assistant-id", .role = .assistant, .timestamp = 0, .content = &.{
        .{ .thinking = .{ .text = "reason" } }, .{ .text = "answer" }, .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = arguments } },
    }, .usage = .{ .input = 12, .output = 5 } }};
    state.snapshot = .{
        .revision = 1,
        .info = .{ .id = "s", .location = "/tmp", .created = 0, .title = title },
        .options = .{ .model = "model" },
        .running = true,
        .inbox = &.{.{ .id = "inbox", .text = "queued", .delivery = .queue }},
        .pendingPermissions = &.{.{ .id = "p", .action = "edit", .pattern = "*", .expiresAt = 0 }},
        .messages = &entries,
        .inflight = null,
        .nextBefore = null,
    };
    try sync(&app, &state);
    @memset(title, 'X');
    @memset(arguments, 'Y');
    try std.testing.expectEqualStrings("Session title", app.title);
    try std.testing.expectEqualStrings("reason", app.messages.items[0].thinking);
    try std.testing.expectEqualStrings("answer", app.messages.items[1].text);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", app.messages.items[2].text);
    try std.testing.expect(app.messages.items[2].tool_running);
    try std.testing.expectEqualStrings("queued", app.pending.items[0].text);
    try std.testing.expectEqualStrings("edit", app.permission.?.action);
    try std.testing.expectEqual(@as(u64, 12), app.usage_input);
    try std.testing.expectEqual(@as(u64, 5), app.usage_output);
}

test "completed tool result clears outstanding call and retains error status" {
    const a = std.testing.allocator;
    var app = App.init(a, "/tmp");
    defer app.deinit();
    var state = client.state.State.init(a);
    defer state.deinit();
    const entries = [_]proto.Message{
        .{ .id = "assistant", .role = .assistant, .timestamp = 0, .content = &.{.{ .tool_call = .{ .id = "call", .name = "write", .arguments = "{}" } }} },
        .{ .id = "result", .role = .tool_result, .timestamp = 1, .content = &.{.{ .text = "failed" }}, .toolCallId = "call", .toolName = "write", .isError = true, .changes = &.{.{ .path = "x", .before = "old", .after = "new", .truncated = true }} },
    };
    state.snapshot = .{ .revision = 1, .info = .{ .id = "s", .location = "/tmp", .created = 0 }, .options = .{}, .running = true, .inbox = &.{}, .pendingPermissions = &.{}, .messages = &entries, .inflight = null, .nextBefore = null };
    try sync(&app, &state);
    try std.testing.expectEqual(@as(usize, 1), app.messages.items.len);
    try std.testing.expect(!app.messages.items[0].tool_running);
    try std.testing.expect(app.messages.items[0].is_error);
    try std.testing.expectEqualStrings("failed", app.messages.items[0].output);
    try std.testing.expectEqualStrings("new", app.messages.items[0].changes[0].after);
}

test "finished turns get a footer with their duration and outcome" {
    const a = std.testing.allocator;
    var app = App.init(a, "/tmp");
    defer app.deinit();
    var state = client.state.State.init(a);
    defer state.deinit();
    const entries = [_]proto.Message{
        .{ .id = "u1", .role = .user, .timestamp = 1_000, .content = &.{.{ .text = "go" }} },
        .{ .id = "a1", .role = .assistant, .timestamp = 2_000, .completedAt = 65_000, .stopReason = .stop, .content = &.{.{ .text = "done" }} },
        .{ .id = "u2", .role = .user, .timestamp = 70_000, .content = &.{.{ .text = "again" }} },
        .{ .id = "a2", .role = .assistant, .timestamp = 71_000, .completedAt = 72_000, .stopReason = .aborted, .content = &.{} },
    };
    state.snapshot = .{ .revision = 1, .info = .{ .id = "s", .location = "/tmp", .created = 0 }, .options = .{}, .running = false, .inbox = &.{}, .pendingPermissions = &.{}, .messages = &entries, .inflight = null, .nextBefore = null };
    try sync(&app, &state);
    var turns: [2]App.Turn = undefined;
    var n: usize = 0;
    for (app.messages.items) |m| if (m.turn) |t| {
        turns[n] = t;
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i64, 64_000), turns[0].ended - turns[0].started);
    try std.testing.expect(turns[1].outcome == .stopped);

    // Stopped during a tool call: no final reply, still a footer.
    const cut = [_]proto.Message{
        .{ .id = "u1", .role = .user, .timestamp = 1_000, .content = &.{.{ .text = "go" }} },
        .{ .id = "a1", .role = .assistant, .timestamp = 2_000, .completedAt = 3_000, .stopReason = .tool_use, .content = &.{.{ .tool_call = .{ .id = "c", .name = "bash", .arguments = "{}" } }} },
        .{ .id = "r1", .role = .tool_result, .timestamp = 9_000, .toolCallId = "c", .toolName = "bash", .isError = true, .content = &.{.{ .text = "interrupted" }} },
    };
    state.snapshot.?.messages = &cut;
    try sync(&app, &state);
    const last = app.messages.items[app.messages.items.len - 1].turn.?;
    try std.testing.expect(last.outcome == .stopped);
    try std.testing.expectEqual(@as(i64, 8_000), last.ended - last.started);
}
