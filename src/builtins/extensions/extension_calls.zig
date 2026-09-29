//! Dispatches calls from an extension into its host.
const std = @import("std");
const core = @import("core");
const providers = @import("providers.zig");
const Extension = @import("Extension.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

/// Calls from the extension.
pub fn answer(ctx: ?*anyopaque, arena: Allocator, io: Io, method: []const u8, params: Value) anyerror![]const u8 {
    const e: *Extension = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, method, "log")) {
        const message = field(params, "message") orelse return error.InvalidParams;
        const level = field(params, "level") orelse "info";
        const name = e.name orelse "?";
        if (std.mem.eql(u8, level, "error")) std.log.err("extension {s}: {s}", .{ name, message }) else if (std.mem.eql(u8, level, "warn")) std.log.warn("extension {s}: {s}", .{ name, message }) else std.log.info("extension {s}: {s}", .{ name, message });
        return "null";
    }
    const rt = e.host.runtime orelse return error.Unavailable;
    if (std.mem.eql(u8, method, "registry")) {
        const location = field(params, "location") orelse e.location orelse return error.InvalidParams;
        const cfg = try core.config.load(arena, io, e.host.env, e.host.config_dir, location);
        return std.json.Stringify.valueAlloc(arena, try core.inspect.registry(rt, arena, location, cfg), .{});
    }
    if (std.mem.eql(u8, method, "messages")) {
        const session = field(params, "session") orelse return error.InvalidParams;
        const page = try rt.messages(arena, session, null, 200);
        return std.json.Stringify.valueAlloc(arena, .{ .messages = page.messages, .nextBefore = page.nextBefore }, .{});
    }
    if (std.mem.eql(u8, method, "credential")) {
        const id = field(params, "provider") orelse return error.InvalidParams;
        return std.json.Stringify.valueAlloc(arena, .{ .apiKey = try providers.credential(e, arena, io, id) }, .{});
    }
    return error.UnknownMethod;
}

fn field(v: Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return switch (v.object.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
