//! Draws the editor input in the dock: wrapped rows with one column of
//! padding, scrolled so the cursor stays visible.
const std = @import("std");
const Screen = @import("screen.zig").Screen;
const width = @import("width.zig");

pub const Cursor = struct { x: usize, y: usize };

/// Blank columns on each side of the text.
const pad = 1;

const Layout = struct { rows: usize, cursor_row: usize };

/// Wraps `text` like `draw` does: rows in total and the cursor's row.
fn layout(text: []const u8, cols: usize, cursor_byte: usize) Layout {
    const content_width = @max(@as(usize, 1), cols -| 2 * pad);
    var row: usize = 0;
    var col: usize = 0;
    var cursor_row: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const end = width.clusterEnd(text, at);
        const r = text[at..end];
        if (at == cursor_byte) cursor_row = row;
        at = end;
        if (r.len == 1 and r[0] == '\n') {
            row += 1;
            col = 0;
            continue;
        }
        const columns = width.displayWidth(r);
        if (col + columns > content_width) {
            row += 1;
            col = 0;
            // A wrapped cluster puts the cursor on its new row.
            if (at - r.len == cursor_byte) cursor_row = row;
        }
        col += columns;
    }
    if (at == cursor_byte) cursor_row = row;
    return .{ .rows = row + 1, .cursor_row = cursor_row };
}

pub fn rowCount(text: []const u8, cols: usize) usize {
    return layout(text, cols, text.len).rows;
}

/// Shows the last `max_rows` rows, or earlier ones when the cursor is above
/// them. Returns the terminal cursor position.
pub fn draw(screen: *Screen, text: []const u8, cursor_byte: usize, top: usize, max_rows: usize) Cursor {
    const content_width = @max(@as(usize, 1), screen.cols -| 2 * pad);
    const shape = layout(text, screen.cols, cursor_byte);
    const first = @min(shape.rows -| max_rows, shape.cursor_row);
    var row: usize = 0;
    var col: usize = 0;
    var byte: usize = 0;
    var cursor: Cursor = .{ .x = pad, .y = top };
    while (byte < text.len) {
        const end = width.clusterEnd(text, byte);
        const r = text[byte..end];
        if (r.len == 1 and r[0] == '\n') {
            if (byte == cursor_byte) cursor = .{ .x = pad + col, .y = top + row -| first };
            row += 1;
            col = 0;
            byte = end;
            continue;
        }
        const columns = width.displayWidth(r);
        if (col + columns > content_width) {
            row += 1;
            col = 0;
        }
        if (byte == cursor_byte) cursor = .{ .x = pad + col, .y = top + row -| first };
        if (row >= first and row - first < max_rows) screen.drawText(pad + col, top + row - first, r);
        col += columns;
        byte = end;
    }
    if (byte == cursor_byte) cursor = .{ .x = pad + col, .y = top + row -| first };
    return .{ .x = @min(cursor.x, screen.cols - 1), .y = @min(@max(cursor.y, top), top + max_rows - 1) };
}

test "the viewport follows a cursor above the last rows" {
    var screen = try Screen.init(std.testing.allocator, 20, 10);
    defer screen.deinit();
    const text = "one\ntwo\nthree\nfour\nfive";
    // Cursor at the end: the last two rows are shown.
    try std.testing.expectEqual(Cursor{ .x = 5, .y = 1 }, draw(&screen, text, text.len, 0, 2));
    // Cursor on "two": the window scrolls up to start at that row.
    const at_two = std.mem.indexOf(u8, text, "two").?;
    try std.testing.expectEqual(Cursor{ .x = 1, .y = 0 }, draw(&screen, text, at_two + 0, 0, 2));
    try std.testing.expectEqual(@as(usize, 5), rowCount(text, 20));
}

test "a wrapped row counts the cursor on its new row" {
    // Width 6 leaves 4 columns: "abcd" fills a row, "e" wraps.
    const shape = layout("abcde", 6, 4);
    try std.testing.expectEqual(@as(usize, 2), shape.rows);
    try std.testing.expectEqual(@as(usize, 1), shape.cursor_row);
}
