//! The runtime's side of questions plugins ask the user (see
//! `elicitation.zig`).
const std = @import("std");
const plugin = @import("plugin");
const Runtime = @import("Runtime.zig");
const elicitation = @import("elicitation.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What plugins ask through; `rt` must outlive them.
pub fn asker(rt: *Runtime) plugin.ask.Asker {
    return .{ .ctx = rt, .ask = ask };
}

fn asks(rt: *Runtime) *elicitation.Asks {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    if (rt.asks == null) rt.asks = .init(rt.gpa, rt.io, rt.bus, &rt.ids);
    return &rt.asks.?;
}

fn ask(ctx: ?*anyopaque, arena: Allocator, _: Io, question: plugin.ask.Question) anyerror!plugin.ask.Answer {
    const rt: *Runtime = @ptrCast(@alignCast(ctx.?));
    return asks(rt).ask(arena, question);
}

/// False for an unknown or already answered question; see
/// `Asks.reply` for content that does not fit.
pub fn reply(rt: *Runtime, arena: Allocator, id: []const u8, action: plugin.ask.Action, content: ?[]const u8, problem: *[]const u8) !bool {
    return asks(rt).reply(arena, id, action, content, problem);
}

/// Open questions for `location`, in `arena`.
pub fn list(rt: *Runtime, arena: Allocator, location: []const u8) ![]const elicitation.Asks.Info {
    return asks(rt).list(arena, location);
}
