//! What an empty conversation shows: the logo, with the name, version and
//! the keys to get started beside it.
const std = @import("std");
const plugin = @import("../plugin.zig");
const Builder = @import("../presentation_text.zig").Builder;
const columns = @import("../presentation_text.zig").columns;

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
/// The least space between the logo and the text.
const gap = 4;
/// Room the text needs beside the logo; below that it shows alone.
const text_width = 36;

fn welcome(v: plugin.View, b: *Builder) anyerror!void {
    if (v.rows < logo.len or v.columns < 2 + logo_width + gap + text_width) {
        for (0..text_lines) |i| {
            try b.add("  ", .normal);
            try text(v, b, i);
            try b.newline();
        }
        return;
    }
    // The logo is centered in the left half of the row and the text, as a
    // left-aligned block, in the right half; a block too wide for its half
    // starts at the middle.
    const half = v.columns / 2;
    const logo_x = (half - logo_width) / 2;
    var block = @max(columns("zeta v" ++ @import("build_options").version), columns(v.app.cwd));
    for (hints) |hint| block = @max(block, key_width + columns(hint[1]));
    const text_x = @max(logo_x + logo_width + gap, half + (half -| block) / 2);
    // Vertically the text is centered on the logo.
    const top = (logo.len - text_lines) / 2;
    for (logo, 0..) |line, y| {
        try space(b, logo_x);
        try b.add(line, .muted);
        if (y >= top and y < top + text_lines) {
            try space(b, text_x - logo_x - columns(line));
            try text(v, b, y - top);
        }
        try b.newline();
    }
}

fn space(b: *Builder, count: usize) !void {
    const spaces = " " ** 64;
    var left = count;
    while (left > 0) : (left -= @min(left, spaces.len)) try b.add(spaces[0..@min(left, spaces.len)], .normal);
}

/// The column the keys' descriptions start at, within the text.
const key_width = 8;

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
            try space(b, key_width -| hint[0].len);
            try b.add(hint[1], .muted);
        },
    }
}
