//! Footer contents: location and status, usage, model.
const std = @import("std");
const plugin = @import("../plugin.zig");
const Builder = @import("../presentation_text.zig").Builder;
const View = plugin.View;

pub const plugin_entry: plugin.Plugin = .{ .id = "bars", .setup = setup };

fn setup(r: *plugin.Registry) anyerror!void {
    try r.addSlot(.{ .slot = .footer_first, .render = location });
    try r.addSlot(.{ .slot = .footer_status, .render = status });
    try r.addSlot(.{ .slot = .footer_left, .render = usage });
    try r.addSlot(.{ .slot = .footer_right, .render = model });
}

fn status(v: View, b: *Builder) anyerror!void {
    if (!v.app.connected) return b.add("○ Reconnecting…", .warning);
    const text = v.app.status;
    if (text.len == 0) return;
    const bad = std.mem.startsWith(u8, text, "Error") or std.mem.startsWith(u8, text, "Request failed") or std.mem.indexOf(u8, text, "failed") != null;
    try b.add(text, if (bad) .failure else .muted);
}

fn location(v: View, b: *Builder) anyerror!void {
    const cwd = v.app.cwd;
    if (v.app.home.len > 1 and std.mem.startsWith(u8, cwd, v.app.home) and (cwd.len == v.app.home.len or cwd[v.app.home.len] == '/')) {
        try b.add("~", .strong);
        try b.add(cwd[v.app.home.len..], .strong);
    } else try b.add(cwd, .strong);
    if (v.app.branch.len > 0) {
        try b.add(" (", .muted);
        try b.add(v.app.branch, .branch);
        try b.add(")", .muted);
    }
}

fn usage(v: View, b: *Builder) anyerror!void {
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (v.app.usage_input > 0 or v.app.usage_output > 0) {
        try w.writeAll("↑");
        try tokens(&w, v.app.usage_input);
        try w.writeAll(" ↓");
        try tokens(&w, v.app.usage_output);
    }
    if (v.app.cost > 0) try w.print(" ${d:.3}", .{v.app.cost});
    if (w.end > 0) try b.add(std.mem.trimStart(u8, w.buffered(), " "), .muted);
    const context = v.app.last_context orelse return;
    if (v.app.context_window == 0) return;
    const percent = @as(f64, @floatFromInt(context)) * 100 / @as(f64, @floatFromInt(v.app.context_window));
    w = .fixed(&buf);
    try w.print("{d:.1}%/", .{percent});
    try tokens(&w, v.app.context_window);
    if (b.used > 0) try b.add(" ", .muted);
    try b.add(w.buffered(), if (percent > 90) .failure else if (percent > 70) .warning else .context);
}

fn model(v: View, b: *Builder) anyerror!void {
    if (v.app.model.len == 0) return;
    try b.add(v.app.model, .muted);
    if (v.app.reasoning or v.app.thinking.len > 0) {
        try b.add(" • ", .muted);
        try b.add(if (v.app.thinking.len > 0) v.app.thinking else "default", .thinking_level);
    }
}

/// 999, 1.2k, 12k, 1.2M.
pub fn tokens(w: *std.Io.Writer, n: u64) !void {
    if (n < 1000) return w.print("{d}", .{n});
    if (n < 10_000) return w.print("{d:.1}k", .{@as(f64, @floatFromInt(n)) / 1000});
    if (n < 1_000_000) return w.print("{d}k", .{n / 1000});
    return w.print("{d:.1}M", .{@as(f64, @floatFromInt(n)) / 1_000_000});
}

test "token counts shorten" {
    var buf: [16]u8 = undefined;
    for ([_]struct { u64, []const u8 }{ .{ 991, "991" }, .{ 1234, "1.2k" }, .{ 272_000, "272k" }, .{ 1_500_000, "1.5M" } }) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try tokens(&w, case[0]);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }
}
