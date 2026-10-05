//! Mouse selection over the transcript. Positions are (row of the laid-out
//! transcript, cell column), so a selection follows scrolling. Copied text
//! rejoins wrapped rows and leaves out layout cells.
const std = @import("std");
const p = @import("presentation_text.zig");
const width = @import("width.zig");

pub const Point = struct {
    line: usize,
    col: usize,

    fn before(a: Point, b: Point) bool {
        return a.line < b.line or a.line == b.line and a.col < b.col;
    }
};

/// Rows `start.line` to `end.line`; `end.col` is exclusive.
pub const Range = struct {
    start: Point,
    end: Point,

    /// The columns selected on `line` (end exclusive), if any.
    pub fn columns(r: Range, line: usize) ?[2]usize {
        if (line < r.start.line or line > r.end.line) return null;
        return .{ if (line == r.start.line) r.start.col else 0, if (line == r.end.line) r.end.col else std.math.maxInt(usize) };
    }
};

/// Where the transcript was last drawn: its first screen row, the rows
/// drawn, the transcript row at the top, and the transcript's length.
pub const Viewport = struct { first: usize = 0, height: usize = 0, start: usize = 0, total: usize = 0 };

pub const Unit = enum { cell, word, line };

pub const State = struct {
    /// Where the button went down; null with nothing selected.
    anchor: ?Point = null,
    head: Point = .{ .line = 0, .col = 0 },
    /// What a drag extends by: a double click picks words, a triple lines.
    unit: Unit = .cell,
    dragging: bool = false,
    /// The pointer left the anchor cell, or a word or line was picked.
    moved: bool = false,
    /// While a drag is above (-1) or below (+1) the transcript.
    autoscroll: i8 = 0,
    scrolled_ms: i64 = 0,
    clicks: u8 = 0,
    click_x: u16 = 0,
    click_y: u16 = 0,
    click_ms: i64 = 0,
    /// Set by the view on every frame.
    viewport: Viewport = .{},
    /// The layout the positions belong to (`view.Cache.layout`).
    layout: u64 = 0,
    /// Epoch milliseconds, set by the run loop on every frame.
    now_ms: i64 = 0,
    /// Copy when the button is released; otherwise a right click copies.
    copy_on_release: bool = true,

    pub fn clear(s: *State) void {
        s.anchor = null;
        s.dragging = false;
        s.moved = false;
        s.autoscroll = 0;
    }

    pub fn active(s: *const State) bool {
        return s.anchor != null and s.moved;
    }

    const Hit = struct { point: Point, edge: i8 = 0 };

    /// The transcript position under a screen cell; `edge` says the cell
    /// is above or below the rows drawn.
    fn locate(s: *const State, x: u16, y: u16) ?Hit {
        const vp = s.viewport;
        if (vp.height == 0) return null;
        if (y < vp.first) return .{ .point = .{ .line = vp.start, .col = x }, .edge = -1 };
        if (y >= vp.first + vp.height) return .{ .point = .{ .line = vp.start + vp.height - 1, .col = x }, .edge = 1 };
        return .{ .point = .{ .line = vp.start + y - vp.first, .col = x } };
    }

    pub fn press(s: *State, x: u16, y: u16) void {
        const repeat = s.clicks > 0 and s.clicks < 3 and s.click_x == x and s.click_y == y and s.now_ms - s.click_ms < 400;
        s.clicks = if (repeat) s.clicks + 1 else 1;
        s.click_x = x;
        s.click_y = y;
        s.click_ms = s.now_ms;
        s.clear();
        const hit = s.locate(x, y) orelse return;
        if (hit.edge != 0) return;
        s.anchor = hit.point;
        s.head = hit.point;
        s.unit = switch (s.clicks) {
            1 => .cell,
            2 => .word,
            else => .line,
        };
        s.dragging = true;
        s.moved = s.clicks > 1;
    }

    pub fn drag(s: *State, x: u16, y: u16) void {
        if (!s.dragging) return;
        const hit = s.locate(x, y) orelse return;
        s.head = hit.point;
        s.autoscroll = hit.edge;
        if (!std.meta.eql(s.head, s.anchor.?)) s.moved = true;
    }

    /// Ends a drag; true when it left something selected.
    pub fn release(s: *State) bool {
        if (!s.dragging) return false;
        s.dragging = false;
        s.autoscroll = 0;
        if (!s.moved) s.anchor = null;
        return s.moved;
    }

    /// Rows were added above the transcript.
    pub fn shift(s: *State, rows: usize) void {
        if (s.anchor) |*anchor| anchor.line += rows;
        s.head.line += rows;
    }

    pub fn range(s: *const State, lines: []const p.Line) ?Range {
        const anchor = s.anchor orelse return null;
        if (!s.moved or lines.len == 0) return null;
        const a = extent(lines, anchor, s.unit);
        const h = extent(lines, s.head, s.unit);
        return .{ .start = if (h.start.before(a.start)) h.start else a.start, .end = if (a.end.before(h.end)) h.end else a.end };
    }
};

/// What `unit` covers around `point`.
fn extent(lines: []const p.Line, point: Point, unit: Unit) Range {
    const at: Point = .{ .line = @min(point.line, lines.len - 1), .col = point.col };
    switch (unit) {
        .cell => return .{ .start = at, .end = .{ .line = at.line, .col = at.col +| 1 } },
        .word => {
            const cols = word(lines[at.line], at.col);
            return .{ .start = .{ .line = at.line, .col = cols[0] }, .end = .{ .line = at.line, .col = cols[1] } };
        },
        .line => {
            var first = at.line;
            while (first > 0 and lines[first].continues != .no) first -= 1;
            var last = at.line;
            while (last + 1 < lines.len and lines[last + 1].continues != .no) last += 1;
            return .{ .start = .{ .line = first, .col = 0 }, .end = .{ .line = last, .col = std.math.maxInt(usize) } };
        },
    }
}

/// One grapheme cluster of a row and the cell it starts at.
const Cells = struct {
    spans: []const p.Span,
    span: usize = 0,
    inner: width.Iterator = .{ .input = "" },
    col: usize = 0,

    const Cell = struct { bytes: []const u8, col: usize, columns: usize, link: ?[]const u8 };

    fn next(c: *Cells) ?Cell {
        while (true) {
            if (c.inner.next()) |cluster| {
                defer c.col += cluster.columns;
                return .{ .bytes = cluster.bytes, .col = c.col, .columns = cluster.columns, .link = c.spans[c.span - 1].link };
            }
            if (c.span >= c.spans.len) return null;
            c.inner = .{ .input = c.spans[c.span].text };
            c.span += 1;
        }
    }
};

/// The columns of the run of word characters, spaces, or the single other
/// character at `col`.
fn word(line: p.Line, col: usize) [2]usize {
    const Class = enum { layout, space, word, other };
    var cells: Cells = .{ .spans = line.spans };
    var start: usize = 0;
    var class: ?Class = null;
    var found = false;
    while (cells.next()) |cell| {
        const this: Class = if (cell.col < line.indent)
            .layout
        else if (cell.bytes[0] == ' ')
            .space
        else if (cell.bytes[0] >= 0x80 or std.ascii.isAlphanumeric(cell.bytes[0]) or cell.bytes[0] == '_')
            .word
        else
            .other;
        if (class == null or this != class.? or this == .other) {
            if (found) return .{ start, cell.col };
            start = cell.col;
            class = this;
        }
        if (col >= cell.col and col < cell.col + cell.columns) found = true;
    }
    return if (found) .{ start, cells.col } else .{ col, col +| 1 };
}

/// The web address the text at `point` opens, if any.
pub fn linkAt(lines: []const p.Line, point: Point) ?[]const u8 {
    if (point.line >= lines.len) return null;
    var cells: Cells = .{ .spans = lines[point.line].spans };
    while (cells.next()) |cell| {
        if (point.col >= cell.col and point.col < cell.col + cell.columns) return cell.link;
    }
    return null;
}

/// The cells of `line` that `r` selects and that hold content.
pub fn shown(line: p.Line, r: Range, index: usize) ?[2]usize {
    const cols = r.columns(index) orelse return null;
    var total: usize = 0;
    for (line.spans) |span| total += p.columns(span.text);
    const from = @max(cols[0], line.indent);
    const to = @min(cols[1], total);
    return if (from < to) .{ from, to } else null;
}

/// The selected text, owned by the caller: wrapped rows are one line again
/// and layout cells are left out.
pub fn text(a: std.mem.Allocator, lines: []const p.Line, r: Range) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var index = r.start.line;
    while (index <= r.end.line and index < lines.len) : (index += 1) {
        const line = lines[index];
        if (index > r.start.line) switch (line.continues) {
            .no => try out.append(a, '\n'),
            .space => try out.append(a, ' '),
            .tight => {},
        };
        const cols = shown(line, r, index) orelse continue;
        var cells: Cells = .{ .spans = line.spans };
        while (cells.next()) |cell| {
            if (cell.col + cell.columns > cols[0] and cell.col < cols[1]) try out.appendSlice(a, cell.bytes);
        }
    }
    return out.toOwnedSlice(a);
}

fn sample(a: std.mem.Allocator) ![]p.Line {
    var b = p.Builder.init(a);
    errdefer b.deinit();
    try b.pad(" ", .normal);
    try b.wrap("alpha beta gamma delta", .normal, 12, " ");
    try b.newline();
    try b.pad(" │ ", .muted);
    try b.add("界x = foo_bar(1)", .normal);
    try b.newline();
    return b.finish();
}

test "a drag selects cells; copied text rejoins wrapped rows without layout" {
    const a = std.testing.allocator;
    const lines = try sample(a);
    defer p.freeLines(a, lines);
    // Rows: " alpha beta", " gamma delta", " │ 界x = foo_bar(1)".
    var s: State = .{ .viewport = .{ .first = 2, .height = 3, .start = 0, .total = 3 } };
    s.press(7, 2);
    try std.testing.expect(!s.active());
    s.drag(5, 4);
    try std.testing.expect(s.release());
    const r = s.range(lines).?;
    const copied = try text(a, lines, r);
    defer a.free(copied);
    try std.testing.expectEqualStrings("beta gamma delta\n界x", copied);
    try std.testing.expectEqual([2]usize{ 3, 6 }, shown(lines[2], r, 2).?);
    // Dragging backwards gives the same range.
    s.press(5, 4);
    s.drag(7, 2);
    try std.testing.expectEqual(r, s.range(lines).?);
}

test "a click selects nothing; two pick a word and three the whole line" {
    const a = std.testing.allocator;
    const lines = try sample(a);
    defer p.freeLines(a, lines);
    var s: State = .{ .viewport = .{ .first = 0, .height = 3, .start = 0, .total = 3 } };
    s.press(12, 2);
    try std.testing.expect(!s.release());
    try std.testing.expect(s.range(lines) == null);
    s.now_ms = 100;
    s.press(12, 2);
    try std.testing.expect(s.release());
    const picked = try text(a, lines, s.range(lines).?);
    defer a.free(picked);
    try std.testing.expectEqualStrings("foo_bar", picked);
    s.now_ms = 200;
    s.press(12, 2);
    s.drag(3, 1);
    const whole = try text(a, lines, s.range(lines).?);
    defer a.free(whole);
    try std.testing.expectEqualStrings("alpha beta gamma delta\n界x = foo_bar(1)", whole);
    // A slow fourth press starts over.
    s.now_ms = 5000;
    s.press(12, 2);
    try std.testing.expectEqual(Unit.cell, s.unit);
}

test "a position on linked text gives its address" {
    const a = std.testing.allocator;
    var b = p.Builder.init(a);
    defer b.deinit();
    try b.pad(" ", .normal);
    try b.wrapLinked("see https://a.test now", .normal, .link, 40, " ");
    const lines = try b.finish();
    defer p.freeLines(a, lines);
    try std.testing.expect(linkAt(lines, .{ .line = 0, .col = 4 }) == null);
    try std.testing.expectEqualStrings("https://a.test", linkAt(lines, .{ .line = 0, .col = 5 }).?);
    try std.testing.expectEqualStrings("https://a.test", linkAt(lines, .{ .line = 0, .col = 18 }).?);
    try std.testing.expect(linkAt(lines, .{ .line = 0, .col = 19 }) == null);
    try std.testing.expect(linkAt(lines, .{ .line = 3, .col = 0 }) == null);
}

test "presses outside the transcript select nothing; drags past it ask to scroll" {
    var s: State = .{ .viewport = .{ .first = 1, .height = 4, .start = 10, .total = 30 } };
    s.press(0, 7);
    try std.testing.expect(s.anchor == null);
    s.press(2, 2);
    s.drag(2, 0);
    try std.testing.expectEqual(@as(i8, -1), s.autoscroll);
    try std.testing.expectEqual(@as(usize, 10), s.head.line);
    s.drag(2, 9);
    try std.testing.expectEqual(@as(i8, 1), s.autoscroll);
    try std.testing.expectEqual(@as(usize, 13), s.head.line);
    s.shift(5);
    try std.testing.expectEqual(@as(usize, 16), s.anchor.?.line);
}
