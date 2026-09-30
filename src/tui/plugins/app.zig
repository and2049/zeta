//! Client commands and their keybindings: provider sign-in, attachments,
//! plugin status, view toggles, help, quit.
const std = @import("std");
const plugin = @import("../plugin.zig");
const auth = @import("../app_auth.zig");
const Context = plugin.Context;

pub const plugin_entry: plugin.Plugin = .{ .id = "app", .setup = setup };

fn setup(r: *plugin.Registry) anyerror!void {
    try r.addCommand(.{ .name = "connect", .description = "Connect a provider", .run = connect });
    try r.addCommand(.{ .name = "attach", .description = "Attach an image", .argument_hint = "<path>", .run = attach });
    try r.addCommand(.{ .name = "reload", .description = "Reload plugins", .run = reload });
    try r.addCommand(.{ .name = "mcp", .description = "MCP servers; with a name, reconnect it", .argument_hint = "[name]", .run = mcp });
    try r.addCommand(.{ .name = "extensions", .description = "Extensions; with a name, restart it", .argument_hint = "[name]", .run = extensions });
    try r.addCommand(.{ .name = "help", .description = "Show keys and commands", .run = help });
    try r.addCommand(.{ .name = "quit", .description = "Exit", .run = quit });
    try r.addCommand(.{ .name = "toggle-tools", .description = "Expand or collapse tool details", .slash = false, .run = toggleTools });
    try r.addCommand(.{ .name = "toggle-thinking", .description = "Expand or collapse thinking and compaction", .slash = false, .run = toggleThinking });
    try r.addKeybind(.{ .ctrl = 'q', .command = "quit" });
    try r.addKeybind(.{ .ctrl = 'o', .command = "toggle-tools" });
    try r.addKeybind(.{ .ctrl = 't', .command = "toggle-thinking" });
}

fn connect(ctx: *Context, _: []const u8) anyerror!void {
    try auth.dispatch(ctx.app, ctx.worker, .list_providers);
}

fn attach(ctx: *Context, path: []const u8) anyerror!void {
    if (path.len == 0) return ctx.app.say("Usage: /attach <path>", .{});
    try ctx.app.attachments.append(ctx.app.allocator, try ctx.app.allocator.dupe(u8, path));
}

fn reload(ctx: *Context, _: []const u8) anyerror!void {
    try ctx.worker.submit(.{ .kind = .reload });
}

fn mcp(ctx: *Context, name: []const u8) anyerror!void {
    try ctx.worker.submit(.{ .kind = .mcp, .text = name });
}

fn extensions(ctx: *Context, name: []const u8) anyerror!void {
    try ctx.worker.submit(.{ .kind = .extensions, .text = name });
}

fn help(ctx: *Context, _: []const u8) anyerror!void {
    ctx.app.overlay = .help;
}

fn quit(ctx: *Context, _: []const u8) anyerror!void {
    ctx.app.quit = true;
}

fn toggleTools(ctx: *Context, _: []const u8) anyerror!void {
    ctx.app.expand_tools = !ctx.app.expand_tools;
    ctx.app.render_revision +%= 1;
}

fn toggleThinking(ctx: *Context, _: []const u8) anyerror!void {
    ctx.app.show_reasoning = !ctx.app.show_reasoning;
    ctx.app.show_compaction = ctx.app.show_reasoning;
    ctx.app.render_revision +%= 1;
}
