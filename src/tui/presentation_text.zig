//! Terminal-independent, owned presentation cells. Call `freeLines` with the
//! same allocator used to render; no span borrows input or emits terminal codes.
const std = @import("std");
const width_util = @import("width.zig");
const A = std.mem.Allocator;

pub const Style = enum { normal, heading, list_marker, code, code_keyword, code_string, code_number, muted, reasoning, user, assistant, tool, tool_name, strong, success, failure, warning, selected, match, accent, added, removed, branch, context, thinking_level, link };
pub const Span = struct { text: []u8, style: Style };
/// How a row follows the one above: on its own, or as the rest of a
/// wrapped line, broken at a space (dropped) or inside a word.
pub const Continues = enum { no, space, tight };
/// `surface` lines get the raised background across the whole row.
/// The first `indent` cells are layout (padding, gutters), not content.
pub const Line = struct { spans: []Span, surface: bool = false, indent: usize = 0, continues: Continues = .no };

pub fn freeLines(a: A, lines: []Line) void {
    for (lines) |line| {
        for (line.spans) |span| a.free(span.text);
        a.free(line.spans);
    }
    a.free(lines);
}

/// Normalize hostile terminal text, replacing control bytes (including ESC,
/// DEL, CR, tabs and invalid UTF-8) with visible '?' before layout.
pub fn clean(a: A, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        const n = std.unicode.utf8ByteSequenceLength(input[i]) catch 1;
        if (i + n > input.len or !std.unicode.utf8ValidateSlice(input[i .. i + n])) {
            try out.append(a, '?');
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(input[i .. i + n]) catch unreachable;
        if (cp < 32 or (cp >= 0x7f and cp < 0xa0) or cp == 0x2028 or cp == 0x2029) {
            try out.append(a, '?');
        } else {
            try out.appendSlice(a, input[i .. i + n]);
        }
        i += n;
    }
    return out.toOwnedSlice(a);
}

pub fn columns(text: []const u8) usize {
    return width_util.displayWidth(text);
}

pub const Builder = struct {
    a: A,
    lines: std.ArrayList(Line) = .empty,
    spans: std.ArrayList(Span) = .empty,
    used: usize = 0,
    /// Lines ended while set are `surface` lines.
    surface: bool = false,
    /// `Line.indent` and `Line.continues` of the row being built.
    indent: usize = 0,
    continues: Continues = .no,

    pub fn init(a: A) Builder {
        return .{ .a = a };
    }
    pub fn deinit(self: *Builder) void {
        for (self.spans.items) |s| self.a.free(s.text);
        self.spans.deinit(self.a);
        for (self.lines.items) |line| {
            for (line.spans) |span| self.a.free(span.text);
            self.a.free(line.spans);
        }
        self.lines.deinit(self.a);
    }
    pub fn add(self: *Builder, text: []const u8, style: Style) !void {
        const safe = try clean(self.a, text);
        errdefer self.a.free(safe);
        try self.spans.append(self.a, .{ .text = safe, .style = style });
        self.used += columns(safe);
    }
    /// Adds layout at the start of a row: padding or a gutter that is not
    /// part of the content.
    pub fn pad(self: *Builder, text: []const u8, style: Style) !void {
        try self.add(text, style);
        self.indent = self.used;
    }
    pub fn newline(self: *Builder) !void {
        const spans = try self.spans.toOwnedSlice(self.a);
        errdefer self.a.free(spans);
        try self.lines.append(self.a, .{ .spans = spans, .surface = self.surface, .indent = self.indent, .continues = self.continues });
        self.used = 0;
        self.indent = 0;
        self.continues = .no;
    }
    /// Appends finished rows (e.g. rendered elsewhere) as they are; the
    /// text is copied.
    pub fn extend(self: *Builder, lines: []const Line) !void {
        for (lines) |line| {
            for (line.spans) |span| try self.add(span.text, span.style);
            self.indent = line.indent;
            self.continues = line.continues;
            try self.newline();
        }
    }
    pub fn finish(self: *Builder) ![]Line {
        if (self.spans.items.len > 0 or self.lines.items.len == 0) try self.newline();
        return self.lines.toOwnedSlice(self.a);
    }
    /// Wrap at the last space that fits, else at a grapheme boundary (a word
    /// longer than the row). The space at a break is dropped. Caller
    /// supplies a prefix after each wrap.
    pub fn wrap(self: *Builder, input: []const u8, style: Style, width: usize, continuation: []const u8) !void {
        const safe = try clean(self.a, input);
        defer self.a.free(safe);
        var it: width_util.Iterator = .{ .input = safe };
        var start: usize = 0;
        var run_width: usize = 0;
        // Just after the run's last space, and the run's width up to there.
        var space_end: usize = 0;
        var space_width: usize = 0;
        var i: usize = 0;
        while (it.next()) |cluster| {
            const w: usize = cluster.columns;
            const is_space = cluster.bytes.len == 1 and cluster.bytes[0] == ' ';
            if (width > 0 and self.used + run_width > 0 and self.used + run_width + w > width) {
                if (is_space) {
                    // Break here and drop the space.
                    if (i > start) try self.add(safe[start..i], style);
                    try self.breakLine(continuation, .space);
                    start = it.index;
                    i = it.index;
                    run_width = 0;
                    space_end = 0;
                    continue;
                }
                if (space_end > start) {
                    try self.add(safe[start .. space_end - 1], style);
                    try self.breakLine(continuation, .space);
                    start = space_end;
                    run_width -= space_width;
                } else {
                    if (i > start) try self.add(safe[start..i], style);
                    try self.breakLine(continuation, .tight);
                    start = i;
                    run_width = 0;
                }
                space_end = 0;
            }
            run_width += w;
            i = it.index;
            if (is_space) {
                space_end = i;
                space_width = run_width;
            }
        }
        if (i > start) try self.add(safe[start..i], style);
    }

    fn breakLine(self: *Builder, continuation: []const u8, how: Continues) !void {
        try self.newline();
        self.continues = how;
        if (continuation.len > 0) try self.pad(continuation, .normal);
    }
};

test "wrapping breaks at spaces and splits only overlong words" {
    const a = std.testing.allocator;
    var b = Builder.init(a);
    defer b.deinit();
    try b.wrap("one two three abcdefghij", .normal, 9, "");
    const lines = try b.finish();
    defer freeLines(a, lines);
    const expected = [_][]const u8{ "one two", "three", "abcdefghi", "j" };
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, line| try std.testing.expectEqualStrings(want, line.spans[0].text);
    for ([_]Continues{ .no, .space, .space, .tight }, lines) |want, line| try std.testing.expectEqual(want, line.continues);
}

test "padding and wrap prefixes count as indent" {
    const a = std.testing.allocator;
    var b = Builder.init(a);
    defer b.deinit();
    try b.pad(" ", .normal);
    try b.wrap("one two", .normal, 5, "   ");
    const lines = try b.finish();
    defer freeLines(a, lines);
    try std.testing.expectEqual(@as(usize, 1), lines[0].indent);
    try std.testing.expectEqual(@as(usize, 3), lines[1].indent);
}

test "escape controls and measure CJK" {
    const a = std.testing.allocator;
    const s = try clean(a, "a\x1b[31m\r中");
    defer a.free(s);
    try std.testing.expectEqualStrings("a?[31m?中", s);
    try std.testing.expectEqual(@as(usize, 9), columns(s));
}

test "wrapping preserves joined emoji and combining clusters" {
    const a = std.testing.allocator;
    var b = Builder.init(a);
    defer b.deinit();
    try b.wrap("ab👩🏽‍💻e\xcc\x81", .normal, 3, "");
    const lines = try b.finish();
    defer freeLines(a, lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("ab", lines[0].spans[0].text);
    try std.testing.expectEqualStrings("👩🏽‍💻e\xcc\x81", lines[1].spans[0].text);
    try std.testing.expectEqual(@as(usize, 3), columns(lines[1].spans[0].text));
}
