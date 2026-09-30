//! Session commands: new, resume, model and thinking level, moving to
//! another directory, compact, undo, fork, rename, queued input, delete.
const std = @import("std");
const plugin = @import("../plugin.zig");
const picker = @import("../picker.zig");
const Context = plugin.Context;

pub const plugin_entry: plugin.Plugin = .{ .id = "session", .setup = setup };

fn setup(r: *plugin.Registry) anyerror!void {
    try r.addCommand(.{ .name = "new", .description = "Start a new session", .run = new });
    try r.addCommand(.{ .name = "resume", .description = "Resume a session", .run = @"resume" });
    try r.addCommand(.{ .name = "model", .description = "Choose the model", .run = model });
    try r.addCommand(.{ .name = "thinking", .description = "Choose the thinking level", .argument_hint = "[level]", .run = thinking });
    try r.addCommand(.{ .name = "cd", .description = "Move this session to another directory's project", .argument_hint = "<dir>", .complete = .directory, .run = cd });
    try r.addCommand(.{ .name = "compact", .description = "Summarize older history", .argument_hint = "[focus]", .run = compact });
    try r.addCommand(.{ .name = "undo", .description = "Undo the latest reply's file changes", .run = undo });
    try r.addCommand(.{ .name = "fork", .description = "Continue in a copy of this session", .run = fork });
    try r.addCommand(.{ .name = "rename", .description = "Rename this session", .argument_hint = "<title>", .run = rename });
    try r.addCommand(.{ .name = "pending", .description = "Edit queued input", .run = pending });
    try r.addCommand(.{ .name = "delete", .description = "Delete this session", .run = delete });
    try r.addKeybind(.{ .ctrl = 'l', .command = "model" });
}

fn new(ctx: *Context, _: []const u8) anyerror!void {
    try ctx.worker.submit(.{ .kind = .create });
}

fn @"resume"(ctx: *Context, _: []const u8) anyerror!void {
    ctx.app.openPicker(.sessions, true);
    try ctx.worker.submit(.{ .kind = .list_sessions });
}

/// Thinking levels, then `auto` for the configured default.
pub const levels = [_]picker.Item{
    .{ .id = "off", .label = "off", .detail = "No reasoning" },
    .{ .id = "minimal", .label = "minimal" },
    .{ .id = "low", .label = "low" },
    .{ .id = "medium", .label = "medium" },
    .{ .id = "high", .label = "high" },
    .{ .id = "xhigh", .label = "xhigh", .detail = "Most reasoning" },
    .{ .id = "auto", .label = "auto", .detail = "Configured default" },
};

fn model(ctx: *Context, _: []const u8) anyerror!void {
    ctx.app.openPicker(.models, true);
    if (ctx.app.session) |id| try ctx.worker.submit(.{ .kind = .list_models, .id = id });
}

fn thinking(ctx: *Context, level: []const u8) anyerror!void {
    if (level.len == 0) {
        ctx.app.openPicker(.thinking, false);
        ctx.app.picker_items = &levels;
        return;
    }
    for (levels) |item| if (std.mem.eql(u8, item.id, level)) {
        if (ctx.app.session) |id| try ctx.worker.submit(.{ .kind = .thinking, .id = id, .text = level });
        return;
    };
    ctx.app.say("Unknown thinking level: {s}", .{level});
}

fn cd(ctx: *Context, typed: []const u8) anyerror!void {
    if (typed.len == 0) return ctx.app.say("Usage: /cd <dir>", .{});
    const id = ctx.app.session orelse return;
    const path = try @import("../completion.zig").absolutePath(ctx.app.allocator, ctx.app.cwd, ctx.app.home, typed);
    defer ctx.app.allocator.free(path);
    try ctx.worker.submit(.{ .kind = .move, .id = id, .text = path });
}

fn rename(ctx: *Context, title: []const u8) anyerror!void {
    if (title.len == 0) return ctx.app.say("Usage: /rename <title>", .{});
    if (ctx.app.session) |id| try ctx.worker.submit(.{ .kind = .rename, .id = id, .text = title });
}

fn delete(ctx: *Context, _: []const u8) anyerror!void {
    if (ctx.app.session) |id| try ctx.worker.submit(.{ .kind = .delete_session, .id = id });
}

fn fork(ctx: *Context, _: []const u8) anyerror!void {
    if (ctx.app.session) |id| try ctx.worker.submit(.{ .kind = .fork, .id = id });
}

fn undo(ctx: *Context, _: []const u8) anyerror!void {
    if (ctx.app.session) |id| try ctx.worker.submit(.{ .kind = .undo, .id = id });
}

fn compact(ctx: *Context, focus: []const u8) anyerror!void {
    const id = ctx.app.session orelse return;
    try ctx.worker.submit(.{ .kind = .compact, .id = id, .text = focus });
}

fn pending(ctx: *Context, _: []const u8) anyerror!void {
    const app = ctx.app;
    app.openPicker(.pending, false);
    if (app.pending_picker_items) |old| app.allocator.free(old);
    _ = app.picker_arena.reset(.retain_capacity);
    const a = app.picker_arena.allocator();
    const items = try app.allocator.alloc(picker.Item, app.pending.items.len);
    for (app.pending.items, items) |item, *dest| dest.* = .{ .id = try a.dupe(u8, item.id), .label = try a.dupe(u8, item.text), .detail = item.delivery };
    app.picker_items = items;
    app.pending_picker_items = items;
}
