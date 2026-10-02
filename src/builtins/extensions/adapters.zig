//! Tools, commands and hooks an extension declares, registered as zeta's
//! own and turned into requests to the extension.
const std = @import("std");
const plugin = @import("plugin");
const Extension = @import("Extension.zig");
const Process = @import("Process.zig");
const register = @import("register.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const hook = plugin.hook;

/// Hook and command requests get this long.
pub const request_ms = 60_000;
/// Tool requests: the host's tool deadline cancels them first.
const tool_idle_ms = 7 * 24 * 60 * 60 * 1000;

const ToolRef = struct { ext: *Extension, name: []const u8 };

/// Registers the declared tools, commands and hooks for `owner`; memory
/// lives in `v`.
pub fn add(e: *Extension, v: Allocator, owner: plugin.Registry.Owner, reg: register.Registration) !void {
    const r = e.host.registry;
    for (reg.tools) |t| {
        const ref = try v.create(ToolRef);
        ref.* = .{ .ext = e, .name = t.name };
        try r.addTool(owner, .{
            .name = t.name,
            .description = t.description,
            .input_schema = t.parameters,
            .side_effect = t.side_effect,
            .timeout_ms = t.timeout_ms,
            .execution_mode = if (t.sequential) .sequential else .parallel,
            .cancellable = t.cancellable,
            .schema_check = .partial,
            .ctx = ref,
            .execute = callTool,
        });
    }
    for (reg.commands) |c| {
        const ref = try v.create(ToolRef);
        ref.* = .{ .ext = e, .name = c.name };
        try r.addCommand(owner, .{ .name = c.name, .description = c.description, .argument_hint = c.argument_hint, .ctx = ref, .run = runCommand });
    }
    for (reg.hooks) |point| try r.addHook(owner, .{ .ctx = e, .point = switch (point) {
        .session_start => .{ .session_start = sessionStart },
        .prompt_submit => .{ .prompt_submit = promptSubmit },
        .tool_pre => .{ .tool_pre = toolPre },
        .tool_post => .{ .tool_post = toolPost },
        .turn_stop => .{ .turn_stop = turnStop },
    } });
}

const Progress = struct {
    sink: plugin.tool.ProgressSink,
    fn event(ctx: ?*anyopaque, value: Value) anyerror!void {
        const self: *Progress = @ptrCast(@alignCast(ctx.?));
        if (value == .object) if (value.object.get("progress")) |p| if (p == .string) try self.sink.emit(p.string);
    }
};

fn callTool(ctx: ?*anyopaque, arena: Allocator, _: Io, location: []const u8, args: Value, sink: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    const ref: *ToolRef = @ptrCast(@alignCast(ctx.?));
    const process = try ref.ext.current();
    var progress: Progress = .{ .sink = sink };
    var failure: Process.Failure = .{};
    const result = process.request(arena, "tool", .{ .name = ref.name, .arguments = args, .location = location, .session = sink.session }, tool_idle_ms, .{ .ctx = &progress, .event = Progress.event }, &failure) catch |err| {
        if (err == error.ExtensionError) return .{ .text = failure.message, .isError = true };
        return err;
    };
    return resultOf(result);
}

fn resultOf(v: Value) plugin.tool.Result {
    if (v != .object) return .{ .text = "", .isError = true };
    return .{
        .text = string(v, "text") orelse "",
        .isError = if (v.object.get("isError")) |b| b == .bool and b.bool else false,
    };
}

fn runCommand(ctx: ?*anyopaque, arena: Allocator, _: Io, location: []const u8, arguments: []const u8, problem: *plugin.command.Problem) anyerror![]const u8 {
    const ref: *ToolRef = @ptrCast(@alignCast(ctx.?));
    var failure: Process.Failure = .{};
    const result = (try ref.ext.current()).request(arena, "command", .{ .name = ref.name, .arguments = arguments, .location = location }, request_ms, null, &failure) catch |err| {
        if (err != error.Canceled and failure.message.len > 0) return problem.fail("{s}", .{failure.message});
        return err;
    };
    return string(result, "text") orelse error.InvalidCommandResult;
}

/// Sends a hook request; `extra` fields join `point`, `location` and `scope`.
fn ask(ctx: ?*anyopaque, arena: Allocator, point: []const u8, scope: hook.Scope, extra: anytype) !Value {
    const e: *Extension = @ptrCast(@alignCast(ctx.?));
    var params: std.json.ObjectMap = .empty;
    try params.put(arena, "point", .{ .string = point });
    try params.put(arena, "location", .{ .string = scope.location });
    try params.put(arena, "scope", try toValue(arena, .{ .session = scope.session, .provider = scope.provider, .model = scope.model }));
    const fields = try toValue(arena, extra);
    for (fields.object.keys(), fields.object.values()) |k, val| try params.put(arena, k, val);
    return (try e.current()).request(arena, "hook", Value{ .object = params }, request_ms, null, null);
}

fn toValue(arena: Allocator, value: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, try std.json.Stringify.valueAlloc(arena, value, .{}), .{});
}

fn action(v: Value) []const u8 {
    return string(v, "action") orelse "continue";
}

fn sessionStart(ctx: ?*anyopaque, arena: Allocator, _: Io, scope: hook.Scope, source: hook.SessionSource) anyerror!?[]const u8 {
    return string(try ask(ctx, arena, "session_start", scope, .{ .source = @tagName(source) }), "context");
}

fn promptSubmit(ctx: ?*anyopaque, arena: Allocator, _: Io, scope: hook.Scope, prompt: hook.Prompt) anyerror!hook.PromptSubmit {
    const r = try ask(ctx, arena, "prompt_submit", scope, .{ .prompt = .{ .id = prompt.id, .text = prompt.text } });
    const kind = action(r);
    if (std.mem.eql(u8, kind, "block")) return .{ .block = string(r, "reason") orelse "Blocked by an extension." };
    if (std.mem.eql(u8, kind, "context")) return .{ .context = string(r, "text") orelse "" };
    return .@"continue";
}

fn callValue(arena: Allocator, call: hook.Call) !Value {
    return toValue(arena, .{ .id = call.id, .name = call.name, .arguments = call.args });
}

fn toolPre(ctx: ?*anyopaque, arena: Allocator, _: Io, scope: hook.Scope, call: hook.Call) anyerror!hook.ToolPre {
    const r = try ask(ctx, arena, "tool_pre", scope, .{ .call = try callValue(arena, call) });
    const kind = action(r);
    if (std.mem.eql(u8, kind, "block")) return .{ .block = string(r, "reason") orelse "Blocked by an extension." };
    if (std.mem.eql(u8, kind, "deny")) return .{ .deny = string(r, "reason") orelse "Denied by an extension." };
    if (std.mem.eql(u8, kind, "rewrite")) return .{ .rewrite = r.object.get("arguments") orelse return error.InvalidHookResult };
    return .@"continue";
}

fn toolPost(ctx: ?*anyopaque, arena: Allocator, _: Io, scope: hook.Scope, call: hook.Call, result: plugin.tool.Result) anyerror!hook.ToolPost {
    const r = try ask(ctx, arena, "tool_post", scope, .{ .call = try callValue(arena, call), .result = .{ .text = result.text, .isError = result.isError } });
    if (!std.mem.eql(u8, action(r), "replace")) return .@"continue";
    const replacement = r.object.get("result") orelse return error.InvalidHookResult;
    var out = resultOf(replacement);
    out.changes = result.changes;
    return .{ .replace = out };
}

fn turnStop(ctx: ?*anyopaque, arena: Allocator, _: Io, scope: hook.Scope, stop: hook.Stop) anyerror!hook.TurnStop {
    const r = try ask(ctx, arena, "turn_stop", scope, .{ .reply = .{ .text = try stop.reply.text(arena) }, .continued = stop.continued });
    if (std.mem.eql(u8, action(r), "continue")) return .{ .@"continue" = string(r, "text") orelse return error.InvalidHookResult };
    return .stop;
}

fn string(v: Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return switch (v.object.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
