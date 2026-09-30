//! What an empty conversation shows: the logo, with the name, version and
//! the keys to get started beside it.
const std = @import("std");
const plugin = @import("../plugin.zig");
const Builder = @import("../presentation_text.zig").Builder;

pub const plugin_entry: plugin.Plugin = .{ .id = "welcome", .setup = setup };

fn setup(r: *plugin.Registry) anyerror!void {
    try r.addSlot(.{ .slot = .welcome, .render = welcome });
}

const logo = [_][]const u8{
    "⠀⠀⠀⠀⠀⠀⣀⣤⣶⠆⠀⠀⠀⠀⠀⠀⠀⣀⣀⡀",
    "⠀⠀⠀⠀⠀⣾⣿⠏⠁⠀⠀⠀⠀⣀⣴⣶⣿⣿⣿⡿",
    "⠀⠀⠀⠀⠈⣿⣿⡀⠀⠀⣠⣶⣿⣿⣿⣿⣿⡿⠋",
    "⠀⠀⠀⠀⠀⠙⠿⣿⣷⣿⣿⣿⡿⠿⠛⠋⠁",
    "⠀⠀⠀⠀⠀⢀⣴⣿⠟⠁",
    "⠀⠀⠀⠀⣠⣿⡿⠋",
    "⠀⠀⠀⣼⣿⠟",
    "⠀⠀⣼⣿⠃",
    "⠀⣸⣿⠏",
    "⠀⣯⡿",
    "⣼⣿⠇",
    "⣷⣿",
    "⡞⣿",
    "⣿⡟⡆",
    "⠸⢿⣟⣀",
    "⠈⢏⡿⣾⣒⣖⣴⡤⣠⣤⣤⣴⣦⣔⣒⡰⡤⣤⢄",
    "⠀⠀⠩⢦⠷⡿⠖⣾⣷⡗⢛⣻⣿⢹⡵⣿⠿⢽⣍⣲",
    "⠀⠀⠀⠈⠉⠳⠿⠿⠾⠗⠘⠮⠎⠿⠚⠻⠨⢩⢝⣚⣆",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⢅⣇",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠊⠏",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⢝⠃",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢬⡠⠹⠡⡀⠦⣒⢯⠊",
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠁⠨⠲⠈",
};

const hints = [_][2][]const u8{
    .{ "/", "commands" },
    .{ "@", "files" },
    .{ "Enter", "send · Ctrl-J new line" },
    .{ "Esc", "stop · Ctrl-Q quit" },
};

/// Name, directory, a blank line, then the keys.
const text_lines = 2 + 1 + hints.len;

const logo_width = blk: {
    @setEvalBranchQuota(100_000);
    var widest: usize = 0;
    for (logo) |line| widest = @max(widest, std.unicode.utf8CountCodepoints(line) catch unreachable);
    break :blk widest;
};
const gap = 4;
/// Room the text needs beside the logo; below that it shows alone.
const text_width = 36;
const spaces = " " ** (logo_width + gap);

fn welcome(v: plugin.View, b: *Builder) anyerror!void {
    if (v.rows < logo.len or v.columns < 2 + logo_width + gap + text_width) {
        for (0..text_lines) |i| {
            try b.add("  ", .normal);
            try text(v, b, i);
            try b.newline();
        }
        return;
    }
    // The text sits beside the logo, centered on it.
    const top = (logo.len - text_lines) / 2;
    for (logo, 0..) |line, y| {
        try b.add("  ", .normal);
        try b.add(line, .muted);
        if (y >= top and y < top + text_lines) {
            const width = std.unicode.utf8CountCodepoints(line) catch logo_width;
            try b.add(spaces[0 .. logo_width - width + gap], .normal);
            try text(v, b, y - top);
        }
        try b.newline();
    }
}

fn text(v: plugin.View, b: *Builder, i: usize) !void {
    switch (i) {
        0 => {
            try b.add("zeta", .accent);
            try b.add(" v" ++ @import("build_options").version, .muted);
        },
        1 => try b.add(v.app.cwd, .muted),
        2 => {},
        else => {
            const hint = hints[i - 3];
            try b.add(hint[0], .strong);
            try b.add(("        ")[0..8 -| hint[0].len], .normal);
            try b.add(hint[1], .muted);
        },
    }
}
