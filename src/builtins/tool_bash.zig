const std = @import("std");
const plugin = @import("plugin");
const platform = @import("platform");

pub const tool: plugin.tool.Tool = .{
    .name = "bash",
    .description = "Execute a bash command in the project directory. Returns combined stdout and stderr (last 2000 lines or 50 KB). Optional timeout in seconds.",
    .input_schema =
    \\{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"number","exclusiveMinimum":0,"maximum":2147483.647}},"required":["command"],"additionalProperties":false}
    ,
    .side_effect = .system,
    .execution_mode = .sequential,
    .execute = execute,
};

fn execute(_: ?*anyopaque, arena: std.mem.Allocator, io: std.Io, location: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
    if (args != .object) return error.InvalidArguments;
    const command = args.object.get("command") orelse return error.InvalidArguments;
    if (command != .string) return error.InvalidArguments;
    var timeout_ms: ?u64 = null;
    if (args.object.get("timeout")) |timeout| {
        const seconds: f64 = switch (timeout) {
            .integer => |v| @floatFromInt(v),
            .float => |v| v,
            else => return error.InvalidTimeout,
        };
        if (!std.math.isFinite(seconds) or seconds <= 0 or seconds > 2_147_483.647) return error.InvalidTimeout;
        timeout_ms = @intFromFloat(@ceil(seconds * 1000));
    }
    const output = try platform.command.run(arena, io, location, command.string, timeout_ms);
    const status: []const u8 = if (output.timed_out)
        try std.fmt.allocPrint(arena, "Command timed out after {d} seconds", .{@as(f64, @floatFromInt(timeout_ms.?)) / 1000})
    else switch (output.term) {
        .exited => |code| if (code == 0) "" else try std.fmt.allocPrint(arena, "Command exited with code {d}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(arena, "Command terminated by signal {d}", .{@intFromEnum(signal)}),
        else => "Command terminated without an exit code",
    };
    const trailer = if (output.truncated) "[Output truncated to last 2000 lines / 50 KB]" else "";
    const text = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}{s}", .{
        output.text,
        if (output.text.len != 0 and output.text[output.text.len - 1] != '\n') "\n" else "",
        trailer,
        if (trailer.len != 0 and status.len != 0) "\n" else "",
        status,
    });
    return .{ .text = if (text.len == 0) "(no output)" else text, .isError = status.len != 0 };
}

test "bash declaration and nonzero result" {
    try std.testing.expectEqual(plugin.tool.SideEffect.system, tool.side_effect);
    try std.testing.expectEqual(plugin.tool.ExecutionMode.sequential, tool.execution_mode);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"echo hello; echo failure >&2; exit 7\"}", .{});
    const sink = plugin.tool.ProgressSink{ .ctx = undefined, .onProgress = struct {
        fn progress(_: *anyopaque, _: []const u8) !void {}
    }.progress };
    const result = try tool.execute(null, arena, std.testing.io, "/tmp", args, sink);
    try std.testing.expect(result.isError);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "hello\n"));
    try std.testing.expect(std.mem.find(u8, result.text, "failure\nCommand exited with code 7") != null);
}
