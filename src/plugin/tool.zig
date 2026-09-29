//! Executable tool capability. Unlike provider.ToolDecl, this owns the host-side
//! execution policy and callback; provider.ToolDecl is only model advertisement.

const std = @import("std");
const provider = @import("provider.zig");
const proto = @import("proto");

pub const SideEffect = enum { none, read, workspace, network, system };
pub const ExecutionMode = enum { parallel, sequential };

/// What a permission rule's pattern is matched against.
pub const Target = enum {
    /// Nothing: the pattern is `*`.
    none,
    /// A filesystem path, canonicalized against the location. A path outside
    /// it also needs the `external_directory` permission.
    path,
    /// A shell command, used as written.
    command,
    /// A URL, used as written.
    url,
    /// Any other string argument, used as written (e.g. a skill name).
    value,
};

pub const Permission = struct {
    /// Rule action; null means the tool name.
    action: ?[]const u8 = null,
    target: Target = .none,
    /// The string argument holding the target. Required unless `none`.
    arg: []const u8 = "",
};

pub const ResultBudget = struct {
    max_lines: usize = 2000,
    max_bytes: usize = 50 * 1024,
};

pub const Result = struct {
    /// Allocated in the call's arena (or otherwise valid until the caller logs it).
    text: []const u8,
    isError: bool = false,
    /// Structured, bounded file changes; owned by the invocation arena.
    changes: []const proto.message.FileChange = &.{},
    /// Images for the model (e.g. a picture the tool read), after the text;
    /// owned by the invocation arena.
    images: []const proto.attachment.Image = &.{},
};

/// Host callbacks for one invocation. Progress text is borrowed for the
/// duration of emit. The dispatcher owns copying it if it needs to retain it
/// for logging or transport.
pub const ProgressSink = struct {
    ctx: *anyopaque,
    /// The session the call belongs to; empty outside a run.
    session: []const u8 = "",
    /// Milliseconds left of the call's deadline when it started; 0 when
    /// unknown.
    remaining_ms: u64 = 0,
    /// Every tool the run can run, deferred ones included; borrowed for the
    /// call.
    tools: []const Tool = &.{},
    onProgress: *const fn (ctx: *anyopaque, partial_result: []const u8) anyerror!void,
    /// Re-runs the host's permission check for this call as if it had been
    /// made with `args` (e.g. a redirect target). Null means no policy gate.
    onPermit: ?*const fn (ctx: *anyopaque, args: std.json.Value) anyerror!bool = null,
    /// Keeps the file at `path` as it is now, so the change the tool is
    /// about to make can be undone. Null when the host keeps nothing.
    onBackup: ?*const fn (ctx: *anyopaque, path: []const u8) anyerror!void = null,

    /// Call right before changing the file at `path` (an absolute path).
    pub fn backup(s: ProgressSink, path: []const u8) !void {
        const keep = s.onBackup orelse return;
        return keep(s.ctx, path);
    }

    pub fn emit(s: ProgressSink, partial_result: []const u8) !void {
        return s.onProgress(s.ctx, partial_result);
    }

    /// True when the host allows the call with `args`. A tool that reaches a
    /// new resource mid-call must ask before touching it.
    pub fn permit(s: ProgressSink, args: std.json.Value) !bool {
        const check = s.onPermit orelse return true;
        return check(s.ctx, args);
    }
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema object serialized as JSON; also used as provider parameters.
    input_schema: []const u8,
    /// Omitted side effects are treated as mutating, never read-only.
    side_effect: SideEffect = .workspace,
    /// How permission rules see a call; checked by the host before execute.
    permission: Permission = .{},
    /// Null inherits the configured tool deadline (120 seconds by default).
    /// An explicit value always overrides it, including 120_000.
    timeout_ms: ?u64 = null,
    /// False: an abort waits for the call to finish (its deadline still
    /// applies) and its real result is recorded.
    cancellable: bool = true,
    result_budget: ResultBudget = .{},
    execution_mode: ExecutionMode = .parallel,
    /// `strict`: the schema may use only keywords the host validates.
    /// `partial`: any JSON Schema object; the host only checks that the
    /// arguments are an object and the tool checks them (tools served by
    /// another program, which knows its own schema).
    schema_check: enum { strict, partial } = .strict,
    /// Runnable, but not offered to the model: a `dispatch` tool reaches it.
    deferred: bool = false,
    /// Takes `{"name", "arguments"}` and runs the deferred tool `name` with
    /// those arguments, through the same schema check, hooks and
    /// permissions as a direct call. Its own `execute` is not used.
    dispatch: bool = false,
    ctx: ?*anyopaque = null,
    /// `arena` owns transient data for this invocation, `location` is the
    /// project root, and `args` is the parsed, validated JSON input. The
    /// caller controls cancellation and enforces timeout/budget policies.
    /// Returned text must survive until the caller records the result.
    execute: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, io: std.Io, location: []const u8, args: std.json.Value, progress: ProgressSink) anyerror!Result,

    pub fn declaration(t: Tool) provider.ToolDecl {
        return .{ .name = t.name, .description = t.description, .parameters = t.input_schema };
    }

    /// A declared target must name a string property of the input schema,
    /// so the host can always find it in validated arguments.
    pub fn checkPermission(t: Tool, input_schema: std.json.Value) error{InvalidPermissionTarget}!void {
        if (t.permission.target == .none) return;
        if (t.permission.arg.len == 0 or input_schema != .object) return error.InvalidPermissionTarget;
        const properties = input_schema.object.get("properties") orelse return error.InvalidPermissionTarget;
        if (properties != .object) return error.InvalidPermissionTarget;
        const property = properties.object.get(t.permission.arg) orelse return error.InvalidPermissionTarget;
        if (property != .object) return error.InvalidPermissionTarget;
        const kind = property.object.get("type") orelse return error.InvalidPermissionTarget;
        if (kind != .string or !std.mem.eql(u8, kind.string, "string")) return error.InvalidPermissionTarget;
    }
};

test "a declared permission target must be a string property" {
    const stub = struct {
        fn execute(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: std.json.Value, _: ProgressSink) anyerror!Result {
            return .{ .text = "ok" };
        }
    }.execute;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"type":"object","properties":{"path":{"type":"string"},"n":{"type":"integer"}}}
    , .{});
    defer parsed.deinit();
    var t: Tool = .{ .name = "x", .description = "", .input_schema = "", .execute = stub };
    try t.checkPermission(parsed.value);
    t.permission = .{ .target = .path, .arg = "path" };
    try t.checkPermission(parsed.value);
    for ([_][]const u8{ "", "n", "missing" }) |arg| {
        t.permission.arg = arg;
        try std.testing.expectError(error.InvalidPermissionTarget, t.checkPermission(parsed.value));
    }
}

test "tool policy defaults are conservative and declaration is advertisement only" {
    const stub = struct {
        fn execute(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: std.json.Value, _: ProgressSink) anyerror!Result {
            return .{ .text = "ok" };
        }
    }.execute;
    const t: Tool = .{ .name = "read", .description = "Read a file", .input_schema = "{}", .execute = stub };
    try std.testing.expectEqual(SideEffect.workspace, t.side_effect);
    try std.testing.expectEqual(@as(?u64, null), t.timeout_ms);
    try std.testing.expect(t.cancellable);
    try std.testing.expectEqual(ExecutionMode.parallel, t.execution_mode);
    try std.testing.expectEqual(Target.none, t.permission.target);
    try std.testing.expectEqual(@as(usize, 2000), t.result_budget.max_lines);
    try std.testing.expectEqual(@as(usize, 50 * 1024), t.result_budget.max_bytes);
    const decl = t.declaration();
    try std.testing.expectEqualStrings(t.name, decl.name);
    try std.testing.expectEqualStrings(t.description, decl.description);
    try std.testing.expectEqualStrings(t.input_schema, decl.parameters);
}

test "execute receives context, location, parsed args, progress, and returns a result" {
    const stub = struct {
        fn execute(ctx: ?*anyopaque, _: std.mem.Allocator, _: std.Io, location: []const u8, args: std.json.Value, sink: ProgressSink) anyerror!Result {
            const visited: *bool = @ptrCast(@alignCast(ctx.?));
            visited.* = true;
            try std.testing.expectEqualStrings("/project", location);
            try std.testing.expectEqualStrings("value", args.string);
            try sink.emit("working");
            return .{ .text = "done", .isError = true };
        }
        fn progress(ctx: *anyopaque, text: []const u8) anyerror!void {
            const visited: *bool = @ptrCast(@alignCast(ctx));
            visited.* = true;
            try std.testing.expectEqualStrings("working", text);
        }
    };
    var ran = false;
    var progressed = false;
    const t: Tool = .{ .name = "x", .description = "x", .input_schema = "{}", .ctx = &ran, .execute = stub.execute };
    const result = try t.execute(t.ctx, std.testing.allocator, std.testing.io, "/project", .{ .string = "value" }, .{ .ctx = &progressed, .onProgress = stub.progress });
    try std.testing.expect(ran and progressed);
    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expect(result.isError);
}
