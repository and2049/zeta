//! Background surfaces derived from the terminal's own background: a shade
//! slightly lighter (dark terminals) or darker (light terminals). No themes;
//! foregrounds stay terminal palette colors.
const std = @import("std");
const Color = @import("screen.zig").Color;

pub const Palette = struct {
    /// Behind user messages and the completion list.
    surface: Color = .{ .indexed = 236 },
    /// The highlighted completion or picker row.
    selected: Color = .{ .indexed = 239 },

    /// `background` is the terminal's answer to the color query (null: none,
    /// assume dark). Without `truecolor` the nearest 256-color entry is used.
    pub fn init(background: ?[3]u8, truecolor: bool) Palette {
        const bg = background orelse return .{};
        const dark = luminance(bg) < 0.5;
        const target: [3]u8 = if (dark) .{ 255, 255, 255 } else .{ 0, 0, 0 };
        return .{
            .surface = color(blend(bg, target, if (dark) 0.10 else 0.06), truecolor),
            .selected = color(blend(bg, target, if (dark) 0.22 else 0.14), truecolor),
        };
    }
};

fn luminance(c: [3]u8) f32 {
    return (0.299 * @as(f32, @floatFromInt(c[0])) + 0.587 * @as(f32, @floatFromInt(c[1])) + 0.114 * @as(f32, @floatFromInt(c[2]))) / 255;
}

fn blend(base: [3]u8, top: [3]u8, alpha: f32) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, base, top) |*o, b, t| {
        const mixed = @as(f32, @floatFromInt(b)) * (1 - alpha) + @as(f32, @floatFromInt(t)) * alpha;
        o.* = @intFromFloat(@round(mixed));
    }
    return out;
}

fn color(rgb: [3]u8, truecolor: bool) Color {
    return if (truecolor) .{ .rgb = rgb } else .{ .indexed = nearest(rgb) };
}

/// The closest xterm-256 entry: the 6x6x6 cube or the 24-step gray ramp.
fn nearest(c: [3]u8) u8 {
    const steps = [_]u8{ 0, 95, 135, 175, 215, 255 };
    var cube: [3]u8 = undefined;
    var cube_rgb: [3]u8 = undefined;
    for (c, &cube, &cube_rgb) |v, *index, *value| {
        var best: u8 = 0;
        for (steps, 0..) |s, i| if (@abs(@as(i16, s) - v) < @abs(@as(i16, steps[best]) - v)) {
            best = @intCast(i);
        };
        index.* = best;
        value.* = steps[best];
    }
    const average: u16 = (@as(u16, c[0]) + c[1] + c[2]) / 3;
    const gray_index: u8 = if (average < 8) 0 else @intCast(@min(23, (average - 8) / 10));
    const gray: u8 = @intCast(8 + @as(u16, gray_index) * 10);
    const cube_color = 16 + 36 * @as(u8, cube[0]) + 6 * @as(u8, cube[1]) + cube[2];
    return if (distance(c, .{ gray, gray, gray }) < distance(c, cube_rgb)) 232 + gray_index else cube_color;
}

fn distance(a: [3]u8, b: [3]u8) u32 {
    var sum: u32 = 0;
    for (a, b) |x, y| {
        const d: i32 = @as(i32, x) - y;
        sum += @intCast(d * d);
    }
    return sum;
}

test "surfaces lighten dark and darken light backgrounds" {
    const dark = Palette.init(.{ 40, 44, 52 }, true);
    try std.testing.expect(dark.surface.rgb[0] > 40);
    const light = Palette.init(.{ 250, 250, 250 }, true);
    try std.testing.expect(light.surface.rgb[0] < 250);
    try std.testing.expectEqual(Color{ .indexed = 236 }, Palette.init(null, true).surface);
}

test "nearest 256-color entry" {
    try std.testing.expectEqual(@as(u8, 16), nearest(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 196), nearest(.{ 255, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 236), nearest(.{ 50, 50, 50 }));
}
