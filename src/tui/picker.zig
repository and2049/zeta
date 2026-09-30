//! Search result ordering and presentation without terminal state. Caller owns
//! items/query; returned indices and lines are separately owned by allocator.
const std = @import("std");
const p = @import("presentation_text.zig");
const width_mod = @import("width.zig");
const A = std.mem.Allocator;
pub const Item = struct { id: []const u8, label: []const u8, detail: []const u8 = "" };
pub const Result = struct {
    indices: []usize,
    selected: usize,
    lines: []p.Line,
    pub fn deinit(self: Result, a: A) void {
        a.free(self.indices);
        p.freeLines(a, self.lines);
    }
};

/// Case-insensitive substring matching over label, id, detail, stable order.
/// Selection is clamped to filtered results; max_visible=0 means no limit.
pub fn render(a: A, items: []const Item, query: []const u8, selected: usize, max_visible: usize, width: usize) !Result {
    var found: std.ArrayList(usize) = .empty;
    errdefer found.deinit(a);
    for (items, 0..) |item, i| {
        if (contains(item.label, query) or contains(item.id, query) or contains(item.detail, query)) try found.append(a, i);
    }
    const indices = try found.toOwnedSlice(a);
    errdefer a.free(indices);
    const choice = if (indices.len == 0) 0 else @min(selected, indices.len - 1);
    var b = p.Builder.init(a);
    errdefer b.deinit();
    if (indices.len == 0) {
        try b.add("  No matches", .muted);
        try b.newline();
    } else {
        const count = if (max_visible == 0) indices.len else @min(max_visible, indices.len);
        const start = if (choice >= count) choice - count + 1 else 0;
        for (indices[start .. start + count], start..) |index, i| {
            const item = items[index];
            const active = i == choice;
            try b.add(if (active) "❯ " else "  ", if (active) .selected else .normal);
            // Truncate safely by cells, not bytes, and keep each item to one row.
            try oneLine(&b, item.label, if (active) .selected else .normal, width);
            if (item.detail.len > 0 and b.used + 3 < width) {
                try b.add(" — ", .muted);
                try oneLine(&b, item.detail, .muted, width);
            }
            try b.newline();
        }
    }
    return .{ .indices = indices, .selected = choice, .lines = try b.finish() };
}
fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
fn oneLine(b: *p.Builder, text: []const u8, style: p.Style, width: usize) !void {
    var i: usize = 0;
    while (i < text.len and (width == 0 or b.used < width)) {
        if (text[i] == '\n' or text[i] == '\r') break;
        // Whole grapheme clusters only: a cut emoji or accent is garbage.
        const end = width_mod.clusterEnd(text, i);
        const chunk = text[i..end];
        const cells: usize = if (chunk[0] < 32 or chunk[0] == 127) 1 else p.columns(chunk);
        if (width != 0 and b.used + cells > width) break;
        try b.add(chunk, style);
        i = end;
    }
}

test "truncation never splits a grapheme cluster" {
    const a = std.testing.allocator;
    // A family emoji is one 2-column cluster of joined code points. Stepping
    // by code point would keep its first person and a dangling joiner.
    var b: p.Builder = .init(a);
    defer b.deinit();
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    try oneLine(&b, "ab" ++ family ++ "c", .normal, 4);
    const lines = try b.finish();
    defer p.freeLines(a, lines);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (lines[0].spans) |span| try text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("ab" ++ family, text.items);
}

test "filter clamp selection and escape labels" {
    const a = std.testing.allocator;
    const r = try render(a, &.{ .{ .id = "a", .label = "Alpha" }, .{ .id = "b", .label = "Be\x1bta", .detail = "target" } }, "TARGET", 8, 4, 24);
    defer r.deinit(a);
    try std.testing.expectEqualSlices(usize, &.{1}, r.indices);
    try std.testing.expectEqual(@as(usize, 0), r.selected);
    try std.testing.expectEqualStrings("?", r.lines[0].spans[3].text);
}
