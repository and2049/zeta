//! Dispatch calls: a tool marked `dispatch` runs the deferred tool its
//! arguments name (`{name, arguments}`), as if that tool had been called.
const std = @import("std");
const plugin = @import("plugin");
const tools = @import("tools.zig");
const Task = tools.Task;

/// The deferred tool a dispatch call names, read ahead of running it.
pub fn named(t: *Task) ?plugin.tool.Tool {
    var scratch: std.heap.ArenaAllocator = .init(t.state.child_allocator);
    defer scratch.deinit();
    const args = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), t.call.arguments, .{}) catch return null;
    if (args != .object) return null;
    const name = switch (args.object.get("name") orelse return null) {
        .string => |n| n,
        else => return null,
    };
    for (t.tools) |candidate| if (candidate.deferred and std.mem.eql(u8, candidate.name, name)) return candidate;
    return null;
}

/// The call's target, with `args` and `shape` replaced by its own; null
/// (with the reason as the result) when there is none or its arguments do
/// not fit.
pub fn resolve(t: *Task, args: *std.json.Value, shape: *std.json.Value) !?plugin.tool.Tool {
    const a = t.state.allocator();
    const name = switch (args.object.get("name") orelse .null) {
        .string => |n| n,
        else => "",
    };
    const target = for (t.tools) |candidate| {
        if (candidate.deferred and std.mem.eql(u8, candidate.name, name)) break candidate;
    } else {
        t.text = try std.fmt.allocPrint(a, "No tool '{s}' to call this way; search for one first.", .{name});
        return null;
    };
    t.target = target;
    args.* = args.object.get("arguments") orelse .{ .object = .empty };
    shape.* = std.json.parseFromSliceLeaky(std.json.Value, a, target.input_schema, .{}) catch {
        t.text = "Tool input schema is malformed.";
        return null;
    };
    if (try tools.checkArgs(a, target, shape.*, args.*)) |problem| {
        t.text = try std.fmt.allocPrint(a, "Invalid arguments for '{s}'{s}", .{ target.name, problem });
        return null;
    }
    return target;
}
