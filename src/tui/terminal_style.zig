//! Terminal styles for semantic spans: palette foregrounds and attributes
//! only, so the user's terminal colors apply. Backgrounds come from
//! `palette.zig`.
const text = @import("presentation_text.zig");
const screen = @import("screen.zig");
const Color = screen.Color;

pub fn styleFor(style: text.Style) screen.Style {
    return switch (style) {
        .normal, .user, .assistant, .tool => .{},
        .heading => .{ .foreground = Color.yellow, .bold = true },
        .list_marker, .code_number => .{ .foreground = Color.cyan },
        .code => .{ .foreground = Color.magenta },
        .code_keyword => .{ .foreground = Color.yellow },
        .code_string, .success, .added => .{ .foreground = Color.green },
        .muted => .{ .dim = true },
        .reasoning => .{ .dim = true, .italic = true },
        .tool_name, .strong, .selected => .{ .bold = true },
        .failure, .removed => .{ .foreground = Color.red },
        .warning => .{ .foreground = Color.yellow },
        .match => .{ .underline = true },
        .accent => .{ .foreground = Color.magenta, .bold = true },
        .branch => .{ .foreground = Color.magenta },
        .link => .{ .foreground = Color.blue, .underline = true },
        .context => .{ .foreground = Color.cyan },
        // Orange is not among the 16 palette colors.
        .thinking_level => .{ .foreground = .{ .indexed = 208 } },
    };
}

/// Editor rule color for a thinking level selection (empty: default).
pub fn ruleColor(level: []const u8) Color {
    const eql = @import("std").mem.eql;
    if (eql(u8, level, "minimal") or eql(u8, level, "low")) return Color.blue;
    if (eql(u8, level, "medium")) return Color.cyan;
    if (eql(u8, level, "high")) return Color.magenta;
    if (eql(u8, level, "xhigh")) return .{ .palette = 13 };
    return Color.gray;
}

test "ordinary content keeps the terminal default" {
    const std = @import("std");
    try std.testing.expectEqual(screen.Style{}, styleFor(.normal));
    try std.testing.expect(styleFor(.reasoning).italic);
    try std.testing.expectEqual(Color.magenta, ruleColor("high"));
}
