//! Performs a tool call through validation, hooks, and timed execution.
const std = @import("std");
const plugin = @import("plugin");
const schema = @import("schema.zig");
const timed = @import("tools_timed.zig");
const dispatch = @import("tools_dispatch.zig");
const Task = @import("tools.zig").Task;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn perform(t: *Task) !void {
    const a = t.state.allocator();
    if (t.truncated) {
        t.text = "Tool call arguments may be truncated (output limit reached); not executed.";
        return;
    }
    var found = t.tool() orelse {
        t.text = try std.fmt.allocPrint(a, "Tool '{s}' is not available.", .{t.call.name});
        return;
    };
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, if (t.call.arguments.len == 0) "{}" else t.call.arguments, .{}) catch {
        t.text = "Invalid tool arguments: malformed JSON.";
        return;
    };
    var shape = std.json.parseFromSliceLeaky(std.json.Value, a, found.input_schema, .{}) catch {
        t.text = "Tool input schema is malformed.";
        return;
    };
    if (try check(a, found, shape, parsed)) |problem| {
        t.text = try std.fmt.allocPrint(a, "Invalid tool arguments{s}", .{problem});
        return;
    }
    if (found.dispatch) {
        // From here on the call is the deferred tool's: its schema and
        // hooks.
        found = try dispatch.resolve(t, &parsed, &shape) orelse return;
    }
    const pre = try t.hooks.toolPre(a, t.io, .{ .id = t.call.id, .name = found.name, .args = parsed });
    if (pre.blocked) |reason| {
        t.text = reason;
        t.denied = pre.denied;
        return;
    }
    const args = pre.args;
    if (pre.rewritten and !try revalidate(t, shape, args)) return;
    // A tool that must not be interrupted runs to its end (or its
    // deadline) and its result is recorded; an abort takes effect after.
    if (!found.cancellable) t.shielded = t.io.swapCancelProtection(.blocked);
    // A failing tool is an error result, which tool_post hooks see too.
    // The files it changed are recorded however the call ended.
    defer timed.settle(t);
    const result = timed.execute(t, found, args) catch |err| blk: {
        if (err == error.Canceled) return err;
        break :blk plugin.tool.Result{ .text = try std.fmt.allocPrint(a, "Tool '{s}' failed: {s}", .{ found.name, @errorName(err) }), .isError = true };
    };
    // Under the shield the result hooks run too (within the deadline),
    // so the model never gets a result they did not see.
    const final = if (t.shielded != null) try timed.post(t, found, args, result) else try t.hooks.toolPost(a, t.io, .{ .id = t.call.id, .name = found.name, .args = args }, result);
    t.text = final.text;
    t.is_error = final.isError;
    t.changes = final.changes;
    t.images = final.images;
    if (t.shielded) |previous| {
        _ = t.io.swapCancelProtection(previous);
        t.shielded = null;
        t.kept = true;
        // An abort that waited for the tool ends the call here.
        try Io.checkCancel(t.io);
    }
}

/// False (with the reason as the result) when hook-rewritten arguments
/// no longer match the tool's schema.
fn revalidate(t: *Task, shape: std.json.Value, args: std.json.Value) !bool {
    const a = t.state.allocator();
    const problem = (try check(a, t.tool().?, shape, args)) orelse return true;
    t.text = try std.fmt.allocPrint(a, "Tool arguments rewritten by a hook are invalid{s}", .{problem});
    return false;
}

/// Why `args` do not fit the tool's schema (": ..." text), or null. A tool
/// that checks its own arguments (`schema_check = .partial`) only gets an
/// object check here: the host could misjudge keywords it does not know.
pub fn check(a: Allocator, tool: plugin.tool.Tool, shape: std.json.Value, args: std.json.Value) !?[]const u8 {
    if (tool.schema_check == .partial) return if (args == .object) null else ": expected an object";
    const issues = try schema.validate(a, shape, args);
    if (issues.len == 0) return null;
    return try std.fmt.allocPrint(a, " at '{s}': {s}", .{ issues[0].path, issues[0].message });
}
