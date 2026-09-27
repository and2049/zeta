//! Calls into a tool, its approval and its result hooks, each within what
//! is left of the call's deadline.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const budget = @import("budget.zig");
const tools = @import("tools.zig");
const Task = tools.Task;
const Approval = tools.Approval;
const Verdict = tools.Verdict;
const Allocator = std.mem.Allocator;
const Io = std.Io;

fn progress(ctx: *anyopaque, partial: []const u8) anyerror!void {
    const t: *Task = @ptrCast(@alignCast(ctx));
    var scratch: std.heap.ArenaAllocator = .init(t.state.child_allocator);
    defer scratch.deinit();
    const found = t.tool().?;
    const limited = try budget.apply(scratch.allocator(), partial, found.result_budget);
    try t.emit(proto.event.types.tool_execution_update, .{
        .toolCallId = t.call.id,
        .toolName = t.call.name,
        .args = t.call.arguments,
        .partialResult = limited,
    });
}

pub fn approve(t: *Task, gate: Approval, found: plugin.tool.Tool, args: *std.json.Value) !Verdict {
    const Event = union(enum) { finished: anyerror!Verdict, deadline: Io.Cancelable!void };
    var storage: [2]Event = undefined;
    var select: Io.Select(Event) = .init(t.io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.finished, invokeApproval, .{ t, gate, found, args });
    const ms = remainingMs(t, found);
    try select.concurrent(.deadline, Io.sleep, .{ t.io, Io.Duration.fromMilliseconds(ms), Io.Clock.awake });
    return switch (try select.await()) {
        .finished => |result| try result,
        .deadline => |expired| blk: {
            try expired;
            break :blk error.Timeout;
        },
    };
}

fn invokeApproval(t: *Task, gate: Approval, found: plugin.tool.Tool, args: *std.json.Value) anyerror!Verdict {
    return gate.check(gate.ctx, t.state.allocator(), t.io, t.location, found, args, t.gateCall());
}

pub fn execute(t: *Task, found: plugin.tool.Tool, args: std.json.Value) !plugin.tool.Result {
    const Event = union(enum) { finished: anyerror!plugin.tool.Result, deadline: Io.Cancelable!void };
    var storage: [2]Event = undefined;
    var select: Io.Select(Event) = .init(t.io, &storage);
    defer select.cancelDiscard(); // Waits for cooperative cleanup before freeing the call arena.
    try select.concurrent(.finished, invoke, .{ t, found, args });
    const ms = remainingMs(t, found);
    try select.concurrent(.deadline, Io.sleep, .{ t.io, Io.Duration.fromMilliseconds(ms), Io.Clock.awake });
    return switch (try select.await()) {
        .finished => |result| try result,
        .deadline => |expired| blk: {
            try expired;
            break :blk error.Timeout;
        },
    };
}

fn invoke(t: *Task, found: plugin.tool.Tool, args: std.json.Value) anyerror!plugin.tool.Result {
    return found.execute(found.ctx, t.state.allocator(), t.io, t.location, args, .{
        .ctx = t,
        .session = t.session,
        .remaining_ms = @intCast(@max(remainingMs(t, found), 0)),
        .onProgress = progress,
        .onPermit = if (t.approval != null) permit else null,
        .onBackup = if (t.artifacts != null) backup else null,
    });
}

/// Keeps a file the tool is about to change (see undo.zig). A copy that
/// cannot be made only means the change cannot be undone.
fn backup(ctx: *anyopaque, path: []const u8) anyerror!void {
    const t: *Task = @ptrCast(@alignCast(ctx));
    const a = t.state.allocator();
    for (t.backed_up.items) |kept| if (std.mem.eql(u8, kept, path)) return;
    const owned = try a.dupe(u8, path);
    @import("undo.zig").backup(a, t.io, t.artifacts.?, t.call.id, t.backed_up.items.len + 1, owned) catch |err| {
        if (err == error.Canceled) return err;
        std.log.warn("{s} not kept for undo: {s}", .{ path, @errorName(err) });
        return;
    };
    try t.backed_up.append(a, owned);
}

/// Records the state of the files the call kept, once it has ended.
pub fn settle(t: *Task) void {
    if (t.backed_up.items.len == 0) return;
    const previous = t.io.swapCancelProtection(.blocked);
    defer _ = t.io.swapCancelProtection(previous);
    @import("undo.zig").settle(t.state.allocator(), t.io, t.artifacts.?, t.call.id, t.backed_up.items) catch |err|
        std.log.warn("undo state not recorded: {s}", .{@errorName(err)});
}

/// Runs the call's approval again with new arguments, inside the tool's
/// deadline. Any refusal marks the call denied, which ends the turn.
fn permit(ctx: *anyopaque, args: std.json.Value) anyerror!bool {
    const t: *Task = @ptrCast(@alignCast(ctx));
    const gate = t.approval.?;
    var checked = args;
    const verdict = gate.check(gate.ctx, t.state.allocator(), t.io, t.location, t.tool().?, &checked, t.gateCall()) catch |err| blk: {
        if (err == error.Canceled) return err;
        break :blk .deny;
    };
    // The tool goes on with the arguments it asked about, so an approval
    // that rewrote them cannot stand.
    const allowed = verdict == .allow and try sameJson(t.state.allocator(), args, checked);
    if (!allowed) t.denied = true;
    return allowed;
}

pub fn remainingMs(t: *Task, found: plugin.tool.Tool) i64 {
    const configured = found.timeout_ms orelse t.timeout_ms orelse 120_000;
    const now = Io.Clock.awake.now(t.io).toMilliseconds();
    const start = t.started_ms orelse blk: {
        t.started_ms = now;
        break :blk now;
    };
    const elapsed = now -| start;
    return @as(i64, @intCast(@min(configured, std.math.maxInt(i64)))) -| elapsed;
}

fn sameJson(arena: Allocator, a: std.json.Value, b: std.json.Value) !bool {
    const left = try std.json.Stringify.valueAlloc(arena, a, .{});
    const right = try std.json.Stringify.valueAlloc(arena, b, .{});
    return std.mem.eql(u8, left, right);
}

/// The tool_post hooks for `result`, within the call's deadline: a tool that
/// must not be interrupted runs them under its shield, and an abort waits
/// for them too. Hooks that run out of time withhold the result.
pub fn post(t: *Task, found: plugin.tool.Tool, args: std.json.Value, result: plugin.tool.Result) !plugin.tool.Result {
    const Event = union(enum) { finished: anyerror!plugin.tool.Result, deadline: Io.Cancelable!void };
    var storage: [2]Event = undefined;
    var select: Io.Select(Event) = .init(t.io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.finished, invokePost, .{ t, found, args, result });
    const ms = remainingMs(t, found);
    try select.concurrent(.deadline, Io.sleep, .{ t.io, Io.Duration.fromMilliseconds(ms), Io.Clock.awake });
    return switch (try select.await()) {
        .finished => |hooked| try hooked,
        .deadline => |expired| blk: {
            try expired;
            break :blk .{ .text = try std.fmt.allocPrint(t.state.allocator(), "Tool '{s}' finished, but its result hooks ran out of time.", .{found.name}), .isError = true };
        },
    };
}

fn invokePost(t: *Task, found: plugin.tool.Tool, args: std.json.Value, result: plugin.tool.Result) anyerror!plugin.tool.Result {
    return t.hooks.toolPost(t.state.allocator(), t.io, .{ .id = t.call.id, .name = found.name, .args = args }, result);
}
