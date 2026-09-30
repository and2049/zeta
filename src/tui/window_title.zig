//! The terminal tab title: `zeta` until the session has a title, then
//! `ζ <title>`. Written only when it changes.
const std = @import("std");
const App = @import("App.zig");
const width = @import("width.zig");

/// Longest session title shown, in columns.
const max_columns = 40;

pub const Title = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    /// Nothing written yet, so the first `update` always writes.
    fresh: bool = true,

    /// The escape sequence to write when the title changed, else null.
    /// The result borrows `out`.
    pub fn update(self: *Title, app: *const App, out: []u8) ?[]const u8 {
        var next: [256]u8 = undefined;
        const text = format(&next, if (app.session != null and app.named) app.title else null);
        if (!self.fresh and std.mem.eql(u8, text, self.buffer[0..self.len])) return null;
        self.fresh = false;
        @memcpy(self.buffer[0..text.len], text);
        self.len = text.len;
        return std.fmt.bufPrint(out, "\x1b]2;{s}\x1b\\", .{text}) catch null;
    }
};

/// Control and escape bytes are dropped; long titles end in `…`.
fn format(buffer: *[256]u8, session_title: ?[]const u8) []const u8 {
    const title = session_title orelse return "zeta";
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll("ζ ") catch unreachable;
    var used: usize = 0;
    var it: width.Iterator = .{ .input = std.mem.trim(u8, title, " ") };
    while (it.next()) |r| {
        if (r.columns == 0 or std.mem.indexOfAny(u8, r.bytes, "\x1b\x07\x7f") != null) continue;
        if (used + r.columns > max_columns - 1) {
            w.writeAll("…") catch {};
            break;
        }
        // Leave room for the ellipsis.
        if (w.end + r.bytes.len + "…".len > buffer.len) break;
        w.writeAll(r.bytes) catch break;
        used += r.columns;
    }
    return w.buffered();
}

test "home and untitled sessions say zeta; titled ones show the title" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    var title: Title = .{};
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]2;zeta\x1b\\", title.update(&app, &out).?);
    try std.testing.expect(title.update(&app, &out) == null);
    app.session = "s";
    app.title = "Untitled session";
    try std.testing.expect(title.update(&app, &out) == null);
    app.named = true;
    app.title = "Fix the parser";
    try std.testing.expectEqualStrings("\x1b]2;ζ Fix the parser\x1b\\", title.update(&app, &out).?);
    app.session = null;
    try std.testing.expectEqualStrings("\x1b]2;zeta\x1b\\", title.update(&app, &out).?);
}

test "titles drop escapes and are shortened" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("ζ ab", format(&buffer, "a\x1b]2;x\x07b"));
    const long = "x" ** 60;
    try std.testing.expectEqualStrings("ζ " ++ "x" ** 39 ++ "…", format(&buffer, long));
}
