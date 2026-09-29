//! An MCP server's tools as zeta tools: named `mcp__<server>__<tool>`,
//! schema checked by the server, run with `tools/call`.
const std = @import("std");
const plugin = @import("plugin");
const core = @import("core");
const Server = @import("Server.zig");
const rpc = @import("rpc.zig");
const names = @import("names.zig");
const requests = @import("requests.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

const ToolRef = struct { server: *Server, remote: []const u8 };

/// Tools for the `tools/list` entries in `listed`; everything lives in `a`.
pub fn build(a: Allocator, s: *Server, listed: []const Value) ![]const plugin.tool.Tool {
    var taken: names.Taken = .{};
    var tools: std.ArrayList(plugin.tool.Tool) = .empty;
    for (listed) |item| {
        if (item != .object) continue;
        const remote = switch (item.object.get("name") orelse .null) {
            .string => |n| n,
            else => continue,
        };
        if (disabled(s.spec.disabled_tools, remote)) continue;
        const schema = item.object.get("inputSchema") orelse Value{ .object = .empty };
        const ref = try a.create(ToolRef);
        ref.* = .{ .server = s, .remote = remote };
        try tools.append(a, .{
            .name = try taken.claim(a, s.spec.name, remote),
            .description = switch (item.object.get("description") orelse .null) {
                .string => |d| d,
                else => "",
            },
            .input_schema = try std.json.Stringify.valueAlloc(a, schema, .{}),
            .schema_check = .partial,
            // The server's hint; a tool that says nothing may change anything.
            .side_effect = if (hint(item, "readOnlyHint")) .read else .system,
            .timeout_ms = s.spec.timeout_ms,
            .deferred = s.spec.deferred,
            .ctx = ref,
            .execute = call,
        });
    }
    return tools.items;
}

fn disabled(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |pattern| if (core.permissions.glob(pattern, name)) return true;
    return false;
}

fn hint(item: Value, name: []const u8) bool {
    const annotations = item.object.get("annotations") orelse return false;
    if (annotations != .object) return false;
    const v = annotations.object.get(name) orelse return false;
    return v == .bool and v.bool;
}

fn call(ctx: ?*anyopaque, arena: Allocator, io: Io, _: []const u8, args: Value, sink: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    const ref: *ToolRef = @ptrCast(@alignCast(ctx.?));
    const s = ref.server;
    s.mutex.lockUncancelable(s.io);
    const link = s.link;
    const connected = s.state == .connected;
    s.mutex.unlock(s.io);
    if (!connected or link == null) return error.McpServerUnavailable;
    // Questions the server asks meanwhile belong to this call.
    var inflight: requests.Call = .{
        .session = sink.session,
        .deadline_ms = if (sink.remaining_ms > 0) Io.Clock.awake.now(io).toMilliseconds() +| @as(i64, @intCast(@min(sink.remaining_ms, std.math.maxInt(i64)))) else null,
    };
    try requests.begin(link.?, &inflight);
    defer requests.end(link.?, &inflight);
    var remote: rpc.Remote = undefined;
    // The tool deadline is the host's; this only needs to outlast it.
    const result = link.?.conn.request(arena, "tools/call", .{ .name = ref.remote, .arguments = args }, rpc.forever_ms, &remote) catch |err| {
        if (err == error.McpRemoteError) return .{ .text = try std.fmt.allocPrint(arena, "MCP error {d}: {s}", .{ remote.code, remote.message }), .isError = true };
        if (err == error.McpUnauthorized and s.signsIn()) s.refused(link.?);
        return err;
    };
    return @import("result.zig").format(arena, result);
}
