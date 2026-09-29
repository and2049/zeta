//! Execute a batch of model tool calls with sequential barriers and ordered results.
//! Each call has a private arena, kept alive until its execution and events settle.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const budget = @import("budget.zig");
const artifact_store = @import("artifacts.zig");
const Hooks = @import("hooks.zig").Hooks;
const timed = @import("tools_timed.zig");
const execution = @import("tools_execution.zig");
const dispatch = @import("tools_dispatch.zig");
const Bus = @import("bus.zig").Bus;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Call = proto.message.ToolCall;

pub const Outcome = struct {
    call: Call,
    text: []const u8,
    is_error: bool,
    denied: bool,
    changes: []const proto.message.FileChange = &.{},
    images: []const proto.attachment.Image = &.{},
};

/// Optional policy gate; called after parsing/schema validation, before the
/// tool is invoked. An approval may replace `args` (a permission hook
/// rewrote them); they are checked against the schema again.
pub const Approval = struct {
    ctx: ?*anyopaque,
    check: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8, tool: plugin.tool.Tool, args: *std.json.Value, call: Call) anyerror!Verdict,
};

pub const Verdict = union(enum) {
    allow,
    /// Denied by policy or the user: the turn ends. An error from the gate
    /// counts as this too.
    deny,
    /// Refused with a reason for the model (a hook); the turn goes on.
    block: []const u8,
};

/// One outcome per call, in call order. `failure` is set when the batch was
/// canceled or failed part-way: calls that finished keep their real results,
/// the rest carry `interrupted`.
pub const Batch = struct {
    outcomes: []Outcome,
    failure: ?anyerror = null,
};

pub const interrupted = "Tool execution interrupted before results were available.";

/// Returned outcomes (including text) belong to `arena`; tools are a frozen
/// snapshot for the duration of this batch. An error return means no tool ran.
/// `artifacts`, when set, is where oversized results are saved in full
/// (see artifacts.zig); without it they are cut at the budget.
pub fn execute(arena: Allocator, gpa: Allocator, io: Io, bus: *Bus, session: []const u8, location: []const u8, tools: []const plugin.tool.Tool, calls: []const Call, truncated: bool, approval: ?Approval, timeout_ms: ?u64, hooks: Hooks, artifacts: ?[]const u8) !Batch {
    const tasks = try arena.alloc(Task, calls.len);
    for (tasks, calls) |*task, call| task.* = .{
        .call = call,
        .tools = tools,
        .io = io,
        .bus = bus,
        .session = session,
        .location = location,
        .truncated = truncated,
        .approval = approval,
        .timeout_ms = timeout_ms,
        .hooks = hooks,
        .artifacts = artifacts,
        .state = .init(gpa),
    };
    defer for (tasks) |*task| task.state.deinit();

    const failure: ?anyerror = if (schedule(io, tasks)) |next| blk: {
        // Every assistant tool call needs a result, but no later barrier may
        // run once permission was denied in an earlier segment.
        for (tasks[next..]) |*task| task.skip() catch |err| break :blk err;
        break :blk null;
    } else |err| err;

    const outcomes = try arena.alloc(Outcome, tasks.len);
    for (tasks, outcomes) |*task, *out| {
        if (!task.finished) task.interrupt();
        out.* = .{
            .call = task.call,
            .text = try arena.dupe(u8, task.text),
            .is_error = task.is_error,
            .denied = task.denied,
            .changes = try copyChanges(arena, task.changes),
            .images = try copyImages(arena, task.images),
        };
    }
    return .{ .outcomes = outcomes, .failure = failure };
}

/// Runs parallel segments and sequential barriers in order. Returns the index
/// of the first task that was not run because of a denial.
fn schedule(io: Io, tasks: []Task) !usize {
    var i: usize = 0;
    while (i < tasks.len) {
        const start = i;
        while (i < tasks.len and !tasks[i].sequential()) : (i += 1) {}
        if (i != start) try parallel(io, tasks[start..i]);
        if (denied(tasks[start..i])) break;
        if (i < tasks.len) {
            try tasks[i].run();
            i += 1;
            // An abort that waited for a tool that must not be interrupted
            // takes effect here, before anything else runs or is written.
            try Io.checkCancel(io);
            if (tasks[i - 1].denied) break;
        }
    }
    return i;
}

fn copyChanges(arena: Allocator, changes: []const proto.message.FileChange) ![]const proto.message.FileChange {
    const copied = try arena.alloc(proto.message.FileChange, changes.len);
    for (changes, copied) |change, *dest| dest.* = .{
        .path = try arena.dupe(u8, change.path),
        .before = try arena.dupe(u8, change.before),
        .after = try arena.dupe(u8, change.after),
        .truncated = change.truncated,
    };
    return copied;
}

fn copyImages(arena: Allocator, images: []const proto.attachment.Image) ![]const proto.attachment.Image {
    const copied = try arena.alloc(proto.attachment.Image, images.len);
    for (images, copied) |image, *dest| dest.* = .{ .mimeType = try arena.dupe(u8, image.mimeType), .data = try arena.dupe(u8, image.data) };
    return copied;
}

fn denied(tasks: []const Task) bool {
    for (tasks) |task| if (task.denied) return true;
    return false;
}

fn parallel(io: Io, tasks: []Task) !void {
    var group: Io.Group = .init;
    errdefer group.cancel(io);
    for (tasks) |*task| try group.concurrent(io, runTask, .{task});
    try group.await(io);
    for (tasks) |*task| if (task.failure) |err| return err;
}

fn runTask(task: *Task) Io.Cancelable!void {
    task.run() catch |err| {
        task.failure = err;
        if (err == error.Canceled) return error.Canceled;
    };
}

pub const Task = struct {
    call: Call,
    tools: []const plugin.tool.Tool,
    io: Io,
    bus: *Bus,
    session: []const u8,
    location: []const u8,
    truncated: bool,
    approval: ?Approval,
    timeout_ms: ?u64,
    hooks: Hooks,
    artifacts: ?[]const u8 = null,
    started_ms: ?i64 = null,
    state: std.heap.ArenaAllocator,
    text: []const u8 = "",
    is_error: bool = true,
    denied: bool = false,
    changes: []const proto.message.FileChange = &.{},
    images: []const proto.attachment.Image = &.{},
    /// Files the tool kept for undo (see undo.zig), in its arena.
    backed_up: std.ArrayList([]const u8) = .empty,
    failure: ?anyerror = null,
    /// `tool.execution.start` was published.
    started: bool = false,
    /// `text` holds the call's final, budgeted result.
    finished: bool = false,
    /// The deferred tool a dispatch call runs.
    target: ?plugin.tool.Tool = null,
    /// Cancel protection before a non-cancellable tool started; restored
    /// once it has returned.
    shielded: ?Io.CancelProtection = null,
    /// A non-cancellable tool finished: `text` holds its result even if the
    /// hooks after it are cancelled.
    kept: bool = false,

    /// The tool that runs: a dispatch call's target once it is known.
    pub fn tool(t: *Task) ?plugin.tool.Tool {
        if (t.target) |target| return target;
        for (t.tools) |candidate| if (std.mem.eql(u8, candidate.name, t.call.name)) return candidate;
        return null;
    }

    fn sequential(t: *Task) bool {
        const found = t.tool() orelse return false;
        if (found.dispatch) if (dispatch.named(t)) |target| return target.execution_mode == .sequential;
        return found.execution_mode == .sequential;
    }

    /// The call as the permission gate sees it: a dispatch call as a call
    /// of its target.
    pub fn gateCall(t: *Task) Call {
        const target = t.target orelse return t.call;
        return .{ .id = t.call.id, .name = target.name, .arguments = t.call.arguments };
    }

    pub fn emit(t: *Task, ty: []const u8, data: anytype) !void {
        try t.bus.publishValue(ty, t.session, t.location, data);
    }

    fn skip(t: *Task) !void {
        t.text = "Tool not executed because an earlier tool was denied permission.";
        t.denied = true;
        t.finished = true;
        try t.emit(proto.event.types.tool_execution_start, .{ .toolCallId = t.call.id, .toolName = t.call.name, .args = t.call.arguments });
        t.started = true;
        try t.limitResult();
        try t.emit(proto.event.types.tool_execution_end, .{
            .toolCallId = t.call.id,
            .toolName = t.call.name,
            .result = .{ .content = &.{.{ .type = "text", .text = t.text }} },
            .isError = true,
        });
    }

    /// Replaces an unfinished result and closes a started execution, so
    /// clients see an end for every start. Best effort: the batch already failed.
    fn interrupt(t: *Task) void {
        t.text = interrupted;
        t.is_error = true;
        t.denied = false;
        t.changes = &.{};
        t.images = &.{};
        if (!t.started) return;
        t.emit(proto.event.types.tool_execution_end, .{
            .toolCallId = t.call.id,
            .toolName = t.call.name,
            .result = .{ .content = &.{.{ .type = "text", .text = t.text }} },
            .isError = true,
        }) catch {};
    }

    fn run(t: *Task) !void {
        defer if (t.shielded) |previous| {
            _ = t.io.swapCancelProtection(previous);
            t.shielded = null;
        };
        try t.emit(proto.event.types.tool_execution_start, .{
            .toolCallId = t.call.id,
            .toolName = t.call.name,
            .args = t.call.arguments,
        });
        t.started = true;
        execution.perform(t) catch |err| {
            if (err != error.Canceled or !t.kept) return err;
            t.limitResult() catch {};
            t.finished = true;
            t.emit(proto.event.types.tool_execution_end, .{
                .toolCallId = t.call.id,
                .toolName = t.call.name,
                .result = .{ .content = &.{.{ .type = "text", .text = t.text }} },
                .isError = t.is_error,
            }) catch {};
            return err;
        };
        try t.limitResult();
        t.finished = true;
        if (t.changes.len > 0) {
            try t.emit(proto.event.types.tool_execution_end, .{
                .toolCallId = t.call.id,
                .toolName = t.call.name,
                .result = .{ .content = &.{.{ .type = "text", .text = t.text }} },
                .isError = t.is_error,
                .changes = t.changes,
            });
        } else try t.emit(proto.event.types.tool_execution_end, .{
            .toolCallId = t.call.id,
            .toolName = t.call.name,
            .result = .{ .content = &.{.{ .type = "text", .text = t.text }} },
            .isError = t.is_error,
        });
    }

    fn limitResult(t: *Task) !void {
        const limits = if (t.tool()) |found| found.result_budget else plugin.tool.ResultBudget{};
        if (budget.fits(t.text, limits)) return;
        const a = t.state.allocator();
        // A result from a tool that ran is kept whole beside the log; the
        // model gets its start and end and the path.
        if (t.artifacts) |directory| if (t.tool() != null and !t.denied) {
            if (artifact_store.save(a, t.io, directory, t.call.id, t.text)) |path| {
                t.text = try artifact_store.preview(a, t.text, limits, path);
                return;
            } else |err| {
                // An abort still counts: whoever checks next sees it.
                if (err == error.Canceled) t.io.recancel() else std.log.warn("tool output not saved: {s}", .{@errorName(err)});
            }
        };
        t.text = try budget.apply(a, t.text, limits);
    }
};

/// Why `args` do not fit the tool's schema, shared with the dispatch helpers.
pub const checkArgs = execution.check;

test {
    _ = timed;
    _ = dispatch;
    _ = @import("tools_test.zig");
    _ = @import("tools_budget_test.zig");
    _ = @import("tools_dispatch_test.zig");
    _ = @import("tools_cancel_test.zig");
}
