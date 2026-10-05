//! Cell framebuffer. drawText sanitizes ANSI/control input before output.
const std = @import("std");
const width = @import("width.zig");

/// A terminal color: the default, one of the 16 palette entries (0-15, so
/// it follows the user's terminal colors), a 256-color index, or RGB.
pub const Color = union(enum) {
    default,
    palette: u4,
    indexed: u8,
    rgb: [3]u8,

    pub const red: Color = .{ .palette = 1 };
    pub const green: Color = .{ .palette = 2 };
    pub const yellow: Color = .{ .palette = 3 };
    pub const blue: Color = .{ .palette = 4 };
    pub const magenta: Color = .{ .palette = 5 };
    pub const cyan: Color = .{ .palette = 6 };
    pub const gray: Color = .{ .palette = 8 };

    fn sgr(self: Color, w: *std.Io.Writer, background: bool) !void {
        const base: u8 = if (background) 40 else 30;
        switch (self) {
            .default => try w.print(";{d}", .{base + 9}),
            .palette => |n| try w.print(";{d}", .{if (n < 8) base + n else base + 60 + (n - 8)}),
            .indexed => |n| try w.print(";{d};5;{d}", .{ base + 8, n }),
            .rgb => |c| try w.print(";{d};2;{d};{d};{d}", .{ base + 8, c[0], c[1], c[2] }),
        }
    }
};
pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

pub const Cell = struct {
    glyph: [96]u8 = [_]u8{0} ** 96,
    len: u8 = 1,
    continuation: bool = false,
    style: Style = .{},
    pub fn blank() Cell {
        var c: Cell = .{};
        c.glyph[0] = ' ';
        return c;
    }
    pub fn eql(a: Cell, b: Cell) bool {
        return std.meta.eql(a.style, b.style) and a.continuation == b.continuation and a.len == b.len and std.mem.eql(u8, a.glyph[0..a.len], b.glyph[0..b.len]);
    }
};

/// Zero-based terminal cursor position.
pub const Cursor = struct { x: usize, y: usize };

pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
    cells: []Cell,
    previous: []Cell,
    invalid: bool = true,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Screen {
        if (cols == 0 or rows == 0 or cols > 1000 or rows > 1000) return error.InvalidDimensions;
        const cells = try allocator.alloc(Cell, cols * rows);
        errdefer allocator.free(cells);
        const previous = try allocator.alloc(Cell, cols * rows);
        @memset(cells, Cell.blank());
        @memset(previous, Cell.blank());
        return .{ .allocator = allocator, .cols = cols, .rows = rows, .cells = cells, .previous = previous };
    }
    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.previous);
    }
    pub fn resize(self: *Screen, cols: usize, rows: usize) !void {
        const next = try init(self.allocator, cols, rows);
        self.deinit();
        self.* = next;
    }
    pub fn clear(self: *Screen) void {
        @memset(self.cells, Cell.blank());
    }

    /// Paints `background` under row `y` from column `x` to the edge,
    /// keeping the text already drawn there.
    pub fn fill(self: *Screen, x: usize, y: usize, background: Color) void {
        if (y >= self.rows) return;
        for (x..self.cols) |col| self.cells[y * self.cols + col].style.background = background;
    }

    /// Paints `background` under cells `x0` up to `x1` of row `y`.
    pub fn fillSpan(self: *Screen, x0: usize, x1: usize, y: usize, background: Color) void {
        if (y >= self.rows) return;
        for (@min(x0, self.cols)..@min(x1, self.cols)) |col| self.cells[y * self.cols + col].style.background = background;
    }

    /// x/y are zero-based. Wide glyphs never straddle the right edge.
    pub fn drawText(self: *Screen, x: usize, y: usize, text: []const u8) void {
        self.drawStyledText(x, y, text, .{});
    }

    pub fn drawStyledText(self: *Screen, x: usize, y: usize, text: []const u8, style: Style) void {
        if (y >= self.rows or x >= self.cols) return;
        var col = x;
        var it: width.Iterator = .{ .input = text };
        while (it.next()) |r| {
            if (r.columns == 0) {
                // An isolated combining mark has no visible base cell.
                continue;
            }
            // Never split a large cluster into invalid UTF-8 or orphan marks.
            const bytes = if (r.bytes.len <= Cell.blank().glyph.len) r.bytes else "�";
            const span: usize = if (r.bytes.len <= Cell.blank().glyph.len) r.columns else 1;
            if (col + span > self.cols) break;
            // Replacing either half of an existing wide cell must invalidate
            // its other half, otherwise the differential frame leaves a
            // visually orphaned glyph behind.
            for (col..col + span) |touched| {
                const old = self.cells[y * self.cols + touched];
                if (old.continuation and touched > 0)
                    self.cells[y * self.cols + touched - 1] = Cell.blank();
                if (!old.continuation and touched + 1 < self.cols and self.cells[y * self.cols + touched + 1].continuation)
                    self.cells[y * self.cols + touched + 1] = Cell.blank();
            }
            var cell = Cell.blank();
            cell.style = style;
            @memcpy(cell.glyph[0..bytes.len], bytes);
            cell.len = @intCast(bytes.len);
            self.cells[y * self.cols + col] = cell;
            if (span == 2) self.cells[y * self.cols + col + 1] = .{ .continuation = true, .len = 0 };
            col += span;
        }
    }

    /// Returns owned synchronized ANSI bytes; caller frees with self.allocator.
    /// Cursor is zero-based and clamped to bounds; null leaves it hidden.
    pub fn render(self: *Screen, cursor: ?Cursor) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
        var current_style: Style = .{};
        if (self.invalid) try w.writeAll("\x1b[2J");
        for (0..self.rows) |y| {
            var x: usize = 0;
            while (x < self.cols) {
                const i = y * self.cols + x;
                if (!self.invalid and Cell.eql(self.cells[i], self.previous[i])) {
                    x += 1;
                    continue;
                }
                // A changed wide continuation is repainted from its lead cell.
                if (self.cells[i].continuation) {
                    x += 1;
                    continue;
                }
                try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                const style = self.cells[i].style;
                if (!std.meta.eql(style, current_style)) {
                    try w.writeAll("\x1b[0");
                    try style.foreground.sgr(w, false);
                    try style.background.sgr(w, true);
                    try w.print("{s}{s}{s}{s}{s}m", .{ if (style.bold) ";1" else "", if (style.dim) ";2" else "", if (style.italic) ";3" else "", if (style.underline) ";4" else "", if (style.reverse) ";7" else "" });
                    current_style = style;
                }
                try w.writeAll(self.cells[i].glyph[0..self.cells[i].len]);
                x += 1;
            }
        }
        try w.writeAll("\x1b[0m");
        if (cursor) |c| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ @min(c.y, self.rows - 1) + 1, @min(c.x, self.cols - 1) + 1 });
        try w.writeAll("\x1b[?2026l");
        @memcpy(self.previous, self.cells);
        self.invalid = false;
        return try self.allocator.dupe(u8, out.written());
    }
};

test "screen diffs, wide cells, escape stripping" {
    var s = try Screen.init(std.testing.allocator, 5, 2);
    defer s.deinit();
    s.drawText(0, 0, "界a\x1b[31m!");
    const first = try s.render(.{ .x = 3, .y = 0 });
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "界") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "[31m") == null);
    const second = try s.render(.{ .x = 3, .y = 0 });
    defer std.testing.allocator.free(second);
    try std.testing.expect(second.len < first.len);
}

test "joined emoji, flag, combining and C1 are atomic safe cells" {
    var s = try Screen.init(std.testing.allocator, 8, 1);
    defer s.deinit();
    s.drawText(0, 0, "👩🏽‍💻🇺🇸e\xcc\x81\xc2\x9b!");
    try std.testing.expectEqualStrings("👩🏽‍💻", s.cells[0].glyph[0..s.cells[0].len]);
    try std.testing.expect(s.cells[1].continuation);
    try std.testing.expectEqualStrings("🇺🇸", s.cells[2].glyph[0..s.cells[2].len]);
    try std.testing.expectEqualStrings("e\xcc\x81", s.cells[4].glyph[0..s.cells[4].len]);
    const out = try s.render(.{ .x = 5, .y = 0 });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xc2\x9b") == null);
}

test "overwriting half a wide cell clears its former lead" {
    var s = try Screen.init(std.testing.allocator, 4, 1);
    defer s.deinit();
    s.drawText(0, 0, "界");
    const first = try s.render(.{ .x = 0, .y = 0 });
    defer std.testing.allocator.free(first);
    s.drawText(1, 0, "x");
    try std.testing.expectEqualStrings(" ", s.cells[0].glyph[0..s.cells[0].len]);
    const second = try s.render(.{ .x = 1, .y = 0 });
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\x1b[1;1H ") != null);
}

test "style-only updates repaint using terminal palette and reset attributes" {
    var s = try Screen.init(std.testing.allocator, 3, 1);
    defer s.deinit();
    s.drawText(0, 0, "a");
    const plain = try s.render(.{ .x = 1, .y = 0 });
    defer std.testing.allocator.free(plain);
    s.drawStyledText(0, 0, "a", .{ .foreground = .green, .bold = true });
    const styled = try s.render(.{ .x = 1, .y = 0 });
    defer std.testing.allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[0;32;49;1ma") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[0m\x1b[1;2H") != null);
}

test "a null cursor stays hidden" {
    var s = try Screen.init(std.testing.allocator, 3, 1);
    defer s.deinit();
    const out = try s.render(null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?25h") == null);
}
