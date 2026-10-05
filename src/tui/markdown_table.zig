//! Markdown (GitHub-style) tables drawn with box characters. Columns get
//! their natural width when the row fits; otherwise the widest columns
//! shrink and their cells wrap. Too narrow for that: one line per row.
const std = @import("std");
const p = @import("presentation_text.zig");
const md = @import("markdown.zig");
const A = std.mem.Allocator;

pub const Align = enum { left, center, right };

/// The cells of a table row (outer pipes optional, `\|` escapes a pipe),
/// or null when the line has no pipe. Slices point into `line`, except
/// escaped ones, which `a` owns.
pub fn cells(a: A, line: []const u8) !?[]const []const u8 {
    var text = std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOfScalar(u8, text, '|') == null) return null;
    if (text.len > 0 and text[0] == '|') text = text[1..];
    if (text.len > 0 and text[text.len - 1] == '|' and !(text.len > 1 and text[text.len - 2] == '\\')) text = text[0 .. text.len - 1];
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    var escaped = false;
    while (i <= text.len) : (i += 1) {
        if (i < text.len and text[i] == '\\' and i + 1 < text.len and text[i + 1] == '|') {
            escaped = true;
            i += 1;
            continue;
        }
        if (i == text.len or text[i] == '|') {
            const cell = std.mem.trim(u8, text[start..i], " \t");
            try out.append(a, if (escaped) try std.mem.replaceOwned(u8, a, cell, "\\|", "|") else cell);
            start = i + 1;
            escaped = false;
        }
    }
    return out.items;
}

/// The alignments of a delimiter row (`|---|:--:|--:|`), or null.
pub fn delimiter(a: A, line: []const u8) !?[]const Align {
    const parts = (try cells(a, line)) orelse return null;
    const aligns = try a.alloc(Align, parts.len);
    for (parts, aligns) |part, *alignment| {
        if (part.len == 0) return null;
        const left = part[0] == ':';
        const right = part[part.len - 1] == ':';
        const dashes = part[@intFromBool(left) .. part.len - @intFromBool(right and part.len > 1)];
        if (dashes.len == 0 or std.mem.indexOfNone(u8, dashes, "-") != null) return null;
        alignment.* = if (left and right) .center else if (right) .right else .left;
    }
    return aligns;
}

/// Draws the table into `b`, each row prefixed by one blank column.
pub fn render(b: *p.Builder, header: []const []const u8, aligns: []const Align, rows: []const []const []const u8, width: usize) !void {
    var scratch: std.heap.ArenaAllocator = .init(b.a);
    defer scratch.deinit();
    const a = scratch.allocator();
    const n = aligns.len;
    // Natural widths from each cell as it will be shown (markup removed).
    const natural = try a.alloc(usize, n);
    // The longest word per column: below that, words split.
    const words = try a.alloc(usize, n);
    @memset(natural, 3);
    @memset(words, 3);
    for (0..rows.len + 1) |r| {
        const cols = if (r == 0) header else rows[r - 1];
        for (0..@min(n, cols.len)) |c| {
            natural[c] = @max(natural[c], try shownWidth(a, cols[c]));
            var it = std.mem.tokenizeScalar(u8, cols[c], ' ');
            while (it.next()) |word| words[c] = @max(words[c], p.columns(word));
        }
    }
    // One column of padding before the table, borders and a space each side.
    const frame = 1 + (n + 1) + 2 * n;
    const available = width -| frame;
    if (available < 3 * n) return plain(b, header, rows, width);
    const widths = try fit(a, natural, words, available);
    // Rows that wrap get a rule between them so they stay apart.
    var wraps = false;
    for (widths, natural) |w, want| wraps = wraps or w < want;
    try border(b, widths, "┌", "┬", "┐");
    _ = try row(b, header, aligns, widths, .strong);
    try border(b, widths, "├", "┼", "┤");
    for (rows, 0..) |cols, i| {
        if (i > 0 and wraps) try border(b, widths, "├", "┼", "┤");
        _ = try row(b, cols, aligns, widths, .normal);
    }
    try border(b, widths, "└", "┴", "┘");
}

/// Column widths summing to at most `available`. Each column gets its
/// natural width if everything fits; else its longest word (when those
/// fit) plus a share of the rest in proportion to what it still wants;
/// else an even share.
fn fit(a: A, natural: []const usize, words: []const usize, available: usize) ![]usize {
    const widths = try a.dupe(usize, natural);
    var total: usize = 0;
    for (widths) |w| total += w;
    if (total <= available) return widths;
    var floor: usize = 0;
    for (natural, words) |want, word| floor += @min(want, word);
    if (floor > available) {
        const share = available / widths.len;
        var extra = available - share * widths.len;
        for (widths) |*w| {
            w.* = share + @as(usize, if (extra > 0) 1 else 0);
            extra -|= 1;
        }
        return widths;
    }
    const spare = available - floor;
    var demand: usize = 0;
    for (natural, words) |want, word| demand += want - @min(want, word);
    var given: usize = 0;
    for (widths, natural, words) |*w, want, word| {
        const base = @min(want, word);
        const more = if (demand == 0) 0 else (want - base) * spare / demand;
        w.* = base + more;
        given += w.*;
    }
    // Rounding leftovers go to the columns still short, first first.
    var left = available -| given;
    for (widths, natural) |*w, want| {
        if (left == 0) break;
        if (w.* < want) {
            w.* += 1;
            left -= 1;
        }
    }
    return widths;
}

fn border(b: *p.Builder, widths: []const usize, left: []const u8, middle: []const u8, right: []const u8) !void {
    try b.add(" ", .normal);
    try b.add(left, .muted);
    for (widths, 0..) |w, i| {
        var bar: std.ArrayList(u8) = .empty;
        defer bar.deinit(b.a);
        for (0..w + 2) |_| try bar.appendSlice(b.a, "─");
        try b.add(bar.items, .muted);
        try b.add(if (i + 1 == widths.len) right else middle, .muted);
    }
    try b.newline();
}

/// One table row; cells wrap within their column and the row grows.
/// Returns its height in lines.
fn row(b: *p.Builder, cols: []const []const u8, aligns: []const Align, widths: []const usize, style: p.Style) !usize {
    var scratch: std.heap.ArenaAllocator = .init(b.a);
    defer scratch.deinit();
    const a = scratch.allocator();
    const wrapped = try a.alloc([]p.Line, widths.len);
    var height: usize = 1;
    for (widths, 0..) |w, c| {
        var cell = p.Builder.init(a);
        try md.inlineSpans(&cell, if (c < cols.len) cols[c] else "", style, w, "");
        wrapped[c] = try cell.finish();
        height = @max(height, wrapped[c].len);
    }
    for (0..height) |line| {
        try b.add(" ", .normal);
        try b.add("│", .muted);
        for (widths, aligns, 0..) |w, alignment, c| {
            const spans: []const p.Span = if (line < wrapped[c].len) wrapped[c][line].spans else &.{};
            var used: usize = 0;
            for (spans) |span| used += p.columns(span.text);
            const gap = w -| used;
            const before = switch (alignment) {
                .left => 0,
                .right => gap,
                .center => gap / 2,
            };
            try pad(b, 1 + before);
            for (spans) |span| try b.addSpan(span);
            try pad(b, 1 + gap - before);
            try b.add("│", .muted);
        }
        try b.newline();
    }
    return height;
}

fn pad(b: *p.Builder, n: usize) !void {
    const spaces = " " ** 64;
    var left = n;
    while (left > 0) {
        const take = @min(left, spaces.len);
        try b.add(spaces[0..take], .normal);
        left -= take;
    }
}

/// Width of a cell once rendered on one line.
fn shownWidth(a: A, source: []const u8) !usize {
    var cell = p.Builder.init(a);
    try md.inlineSpans(&cell, source, .normal, 0, "");
    return cell.used;
}

/// Fallback for very narrow screens: `a · b · c` per row.
fn plain(b: *p.Builder, header: []const []const u8, rows: []const []const []const u8, width: usize) !void {
    for (0..rows.len + 1) |r| {
        const cols = if (r == 0) header else rows[r - 1];
        try b.add(" ", .normal);
        for (cols, 0..) |cell, c| {
            if (c > 0) try b.add(" · ", .muted);
            try md.inlineSpans(b, cell, if (r == 0) .strong else .normal, width, " ");
        }
        try b.newline();
    }
}

fn rowText(lines: []const p.Line, i: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines[i].spans) |span| try out.appendSlice(std.testing.allocator, span.text);
    return out.toOwnedSlice(std.testing.allocator);
}

test "cells and delimiters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = (try cells(a, "| a | b \\| c |  |")).?;
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("b | c", parts[1]);
    try std.testing.expect(try cells(a, "no pipes") == null);
    const aligns = (try delimiter(a, "|---|:---:|--:|")).?;
    try std.testing.expectEqualSlices(Align, &.{ .left, .center, .right }, aligns);
    try std.testing.expect(try delimiter(a, "| a | b |") == null);
}

test "a table that fits keeps natural widths; a wide one wraps its cells" {
    const a = std.testing.allocator;
    var b = p.Builder.init(a);
    defer b.deinit();
    try render(&b, &.{ "Component", "zeta" }, &.{ .left, .right }, &.{&.{ "**Base** prompt", "~20" }}, 80);
    const lines = try b.finish();
    defer p.freeLines(a, lines);
    try std.testing.expectEqual(@as(usize, 5), lines.len);
    const head = try rowText(lines, 1);
    defer a.free(head);
    try std.testing.expectEqualStrings(" │ Component   │ zeta │", head);
    const body = try rowText(lines, 3);
    defer a.free(body);
    try std.testing.expectEqualStrings(" │ Base prompt │  ~20 │", body);

    var narrow = p.Builder.init(a);
    defer narrow.deinit();
    try render(&narrow, &.{ "Part", "Estimate" }, &.{ .left, .left }, &.{&.{ "Built-in tool descriptions and schemas", "Likely 1,500 to 3,000 tokens" }}, 34);
    const wrapped = try narrow.finish();
    defer p.freeLines(a, wrapped);
    try std.testing.expect(wrapped.len > 5);
    for (wrapped, 0..) |_, i| {
        const line = try rowText(wrapped, i);
        defer a.free(line);
        try std.testing.expect(p.columns(line) <= 34);
    }
}
