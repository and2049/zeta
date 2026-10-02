//! Checks and defaults applied to a run's frozen tool snapshot.
const std = @import("std");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Tools without their own deadline inherit the configured one.
pub fn applyTimeouts(executors: []plugin.tool.Tool, fallback_ms: u64) void {
    for (executors) |*tool| tool.timeout_ms = tool.timeout_ms orelse fallback_ms;
}

test "runtime fills inherited timeout but retains explicit 120 seconds" {
    const stub = struct {
        fn execute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
            unreachable;
        }
    }.execute;
    var tools = [_]plugin.tool.Tool{
        .{ .name = "inherited", .description = "", .input_schema = "{}", .execute = stub },
        .{ .name = "specific", .description = "", .input_schema = "{}", .timeout_ms = 120_000, .execute = stub },
    };
    applyTimeouts(&tools, 250);
    try std.testing.expectEqual(@as(?u64, 250), tools[0].timeout_ms);
    try std.testing.expectEqual(@as(?u64, 120_000), tools[1].timeout_ms);
}

/// Per-run tools may not shadow registered ones and must use the supported
/// schema subset, checked before any of them is advertised.
pub fn validatePrepared(arena: Allocator, registered_tools: []const plugin.tool.Tool, added: []const plugin.tool.Tool) !void {
    for (added, 0..) |tool, index| {
        for (registered_tools) |registered| if (std.mem.eql(u8, registered.name, tool.name)) return error.DuplicateRegistration;
        for (added[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, tool.name)) return error.DuplicateRegistration;
        const schema = std.json.parseFromSliceLeaky(std.json.Value, arena, tool.input_schema, .{}) catch return error.InvalidSchema;
        try plugin.schema.check(schema);
    }
}

test "prepared tools reject duplicates and unsupported schema before advertising" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const stub = struct {
        fn execute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
            unreachable;
        }
    }.execute;
    const valid: plugin.tool.Tool = .{ .name = "skill", .description = "", .input_schema = "{}", .execute = stub };
    const unsupported: plugin.tool.Tool = .{ .name = "other", .description = "", .input_schema = "{\"$ref\":\"#/x\"}", .execute = stub };
    try std.testing.expectError(error.DuplicateRegistration, validatePrepared(state.allocator(), &.{valid}, &.{valid}));
    try std.testing.expectError(error.DuplicateRegistration, validatePrepared(state.allocator(), &.{}, &.{ valid, valid }));
    try std.testing.expectError(error.InvalidSchema, validatePrepared(state.allocator(), &.{}, &.{unsupported}));
    try validatePrepared(state.allocator(), &.{}, &.{valid});
}
