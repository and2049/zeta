//! Runs one hook command and reads what it answered. The command gets the
//! event as JSON on stdin (camelCase fields plus snake_case aliases) and
//! `ZETA_PROJECT_DIR`, `ZETA_SESSION_ID` and `CLAUDE_PROJECT_DIR` in its
//! environment. Exit 2 blocks with stderr as the reason. Exit 0 with stdout
//! starting `{` is read as JSON; other stdout is ignored. Any other exit, a
//! timeout or unreadable JSON is a failure.
const std = @import("std");
const plugin = @import("plugin");
const platform = @import("platform");
const file = @import("file.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

pub const max_output = 32 * 1024;

/// What one command asked for; which parts apply depends on the event.
pub const Reply = struct {
    /// Block, deny, or (for Stop) keep going, with this reason.
    block: ?[]const u8 = null,
    /// Permission granted without asking.
    allow: bool = false,
    /// Replacement tool arguments.
    updated_input: ?Value = null,
    /// Text for the model.
    context: ?[]const u8 = null,
};

pub const Invocation = struct {
    command: file.Command,
    scope: plugin.hook.Scope,
    transcript_path: []const u8,
    /// Event-specific fields, added to the common ones.
    fields: []const Field = &.{},
    env: *const std.process.Environ.Map,
};

/// `name` is camelCase; `alias`, when set, is its snake_case twin.
pub const Field = struct { name: []const u8, alias: ?[]const u8 = null, value: Value };

pub fn run(arena: Allocator, io: Io, call: Invocation) !Reply {
    var env = try call.env.clone(arena);
    try env.put("ZETA_PROJECT_DIR", call.scope.location);
    try env.put("ZETA_SESSION_ID", call.scope.session);
    try env.put("CLAUDE_PROJECT_DIR", call.scope.location);
    const out = try platform.hook_process.run(arena, io, .{
        .cwd = call.scope.location,
        .command = call.command.command,
        .input = try payload(arena, call),
        .env = &env,
        .timeout_ms = call.command.timeout_ms,
        .max_output = max_output,
    });
    if (out.timed_out) return error.HookTimedOut;
    const code = out.exit_code orelse return error.HookKilled;
    if (code == 2) {
        const reason = std.mem.trim(u8, out.stderr, " \t\r\n");
        return .{ .block = if (reason.len > 0) reason else "Blocked by a hook." };
    }
    if (code != 0) {
        std.log.warn("hook '{s}' exited with {d}: {s}", .{ call.command.command, code, std.mem.trim(u8, out.stderr, " \t\r\n") });
        return error.HookFailed;
    }
    return interpret(arena, out.stdout);
}

fn payload(arena: Allocator, call: Invocation) ![]const u8 {
    var o: std.json.ObjectMap = .empty;
    const event: Value = .{ .string = @tagName(call.command.event) };
    try o.put(arena, "hookEventName", event);
    try o.put(arena, "hook_event_name", event);
    try o.put(arena, "sessionId", .{ .string = call.scope.session });
    try o.put(arena, "session_id", .{ .string = call.scope.session });
    try o.put(arena, "cwd", .{ .string = call.scope.location });
    try o.put(arena, "transcriptPath", .{ .string = call.transcript_path });
    try o.put(arena, "transcript_path", .{ .string = call.transcript_path });
    try o.put(arena, "provider", .{ .string = call.scope.provider });
    try o.put(arena, "model", .{ .string = call.scope.model });
    for (call.fields) |f| {
        try o.put(arena, f.name, f.value);
        if (f.alias) |alias| try o.put(arena, alias, f.value);
    }
    return std.json.Stringify.valueAlloc(arena, Value{ .object = o }, .{});
}

/// Reads exit-0 stdout. Returned strings live in `arena`.
pub fn interpret(arena: Allocator, stdout: []const u8) !Reply {
    const text = std.mem.trim(u8, stdout, " \t\r\n");
    if (text.len == 0 or text[0] != '{') return .{};
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return error.InvalidHookOutput;
    if (root != .object) return error.InvalidHookOutput;
    const o = root.object;
    var reply: Reply = .{ .context = string(o, "additionalContext") };
    if (o.get("continue")) |go| if (go == .bool and !go.bool) {
        reply.block = string(o, "stopReason") orelse string(o, "reason") orelse "Stopped by a hook.";
    };
    if (string(o, "decision")) |decision| {
        if (std.mem.eql(u8, decision, "block")) reply.block = reply.block orelse string(o, "reason") orelse "Blocked by a hook.";
        if (std.mem.eql(u8, decision, "approve")) reply.allow = true;
    }
    const specific = switch (o.get("hookSpecificOutput") orelse .null) {
        .object => |s| s,
        else => return reply,
    };
    if (string(specific, "additionalContext")) |text_| reply.context = text_;
    if (string(specific, "permissionDecision")) |decision| {
        if (std.mem.eql(u8, decision, "deny")) reply.block = string(specific, "permissionDecisionReason") orelse "Denied by a hook.";
        if (std.mem.eql(u8, decision, "allow")) reply.allow = true;
    }
    if (specific.get("updatedInput")) |input| if (input == .object) {
        reply.updated_input = input;
    };
    if (specific.get("decision")) |d| if (d == .object) {
        const behavior = string(d.object, "behavior") orelse "";
        if (std.mem.eql(u8, behavior, "allow")) reply.allow = true;
        if (std.mem.eql(u8, behavior, "deny")) reply.block = string(d.object, "message") orelse "Denied by a hook.";
        if (d.object.get("updatedInput")) |input| if (input == .object) {
            reply.updated_input = input;
        };
    };
    return reply;
}

fn string(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (o.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

test "json replies: blocks, permission answers, rewritten input and context" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Reply{}, try interpret(a, "plain text is ignored"));
    try testing.expectEqualStrings("nope", (try interpret(a, "{\"decision\":\"block\",\"reason\":\"nope\"}")).block.?);
    try testing.expectEqualStrings("halt", (try interpret(a, "{\"continue\":false,\"stopReason\":\"halt\"}")).block.?);
    const pre = try interpret(a,
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no rm"}}
    );
    try testing.expectEqualStrings("no rm", pre.block.?);
    const rewrite = try interpret(a,
        \\{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"ls"}}}
    );
    try testing.expect(rewrite.allow and rewrite.block == null);
    try testing.expectEqualStrings("ls", rewrite.updated_input.?.object.get("command").?.string);
    const ask = try interpret(a,
        \\{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"not now"}}}
    );
    try testing.expectEqualStrings("not now", ask.block.?);
    try testing.expectEqualStrings("ctx", (try interpret(a, "{\"hookSpecificOutput\":{\"additionalContext\":\"ctx\"}}")).context.?);
    try testing.expectError(error.InvalidHookOutput, interpret(a, "{broken"));
}

test "exit 2 blocks with stderr, other failures are errors, stdin carries the event" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("PATH", "/usr/bin:/bin");
    const base: Invocation = .{
        .command = .{ .event = .PreToolUse, .matcher = "", .command = "", .timeout_ms = 5000 },
        .scope = .{ .session = "ses_1", .location = "/tmp", .provider = "p", .model = "m" },
        .transcript_path = "/t.jsonl",
        .fields = &.{.{ .name = "toolName", .alias = "tool_name", .value = .{ .string = "bash" } }},
        .env = &env,
    };
    var call = base;
    call.command.command = "if grep -q '\"tool_name\":\"bash\"'; then echo \"$ZETA_SESSION_ID\" >&2; exit 2; fi; exit 1";
    try testing.expectEqualStrings("ses_1", (try run(a, testing.io, call)).block.?);
    call.command.command = "exit 1";
    try testing.expectError(error.HookFailed, run(a, testing.io, call));
    call.command.command = "cat >/dev/null; echo '{\"decision\":\"approve\"}'";
    try testing.expect((try run(a, testing.io, call)).allow);
}
