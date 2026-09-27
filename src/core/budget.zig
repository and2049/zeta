//! Model-visible tool output limit. The notice is included in both limits.
const std = @import("std");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;

pub const notice = "\n[Tool output truncated]";

/// Returns arena-owned text when truncated, otherwise borrows input.
pub fn apply(arena: Allocator, text: []const u8, limits: plugin.tool.ResultBudget) Allocator.Error![]const u8 {
    if (fits(text, limits)) return text;
    if (limits.max_bytes == 0 or limits.max_lines == 0) return "";
    if (limits.max_lines == 1) {
        const single = notice[1..];
        return single[0..@min(limits.max_bytes, single.len)];
    }
    if (limits.max_bytes < notice.len) return notice[0..@min(limits.max_bytes, notice.len)];

    var end: usize = 0;
    var lines: usize = 1;
    const available = limits.max_bytes - notice.len;
    while (end < text.len and end < available) {
        const width = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        if (end + width > available or end + width > text.len) break;
        if (text[end] == '\n') {
            if (lines >= limits.max_lines - 1) break;
            lines += 1;
        }
        end += width;
    }
    return std.fmt.allocPrint(arena, "{s}{s}", .{ text[0..end], notice });
}

pub fn fits(text: []const u8, limits: plugin.tool.ResultBudget) bool {
    if (text.len > limits.max_bytes or limits.max_lines == 0) return false;
    var lines: usize = 1;
    for (text) |c| if (c == '\n') {
        lines += 1;
        if (lines > limits.max_lines) return false;
    };
    return true;
}

test "line and byte budgets reserve a notice and preserve UTF-8 boundaries" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("short", try apply(a, "short", .{}));
    const lines = try apply(a, "one\ntwo\nthree", .{ .max_lines = 2 });
    defer a.free(lines);
    try std.testing.expectEqualStrings("one\n[Tool output truncated]", lines);
    const bytes = try apply(a, "éééééééééééééééé", .{ .max_bytes = notice.len + 3 });
    defer a.free(bytes);
    try std.testing.expectEqualStrings("é\n[Tool output truncated]", bytes);
    try std.testing.expect(bytes.len <= notice.len + 3);
}

test "default budget limits both 2000 lines and 50 KiB" {
    const a = std.testing.allocator;
    const lines = try a.alloc(u8, 2001 * 2);
    defer a.free(lines);
    for (0..2001) |i| {
        lines[i * 2] = 'x';
        lines[i * 2 + 1] = '\n';
    }
    const by_lines = try apply(a, lines, .{});
    defer a.free(by_lines);
    try std.testing.expect(std.mem.endsWith(u8, by_lines, notice));
    try std.testing.expectEqual(@as(usize, 2000), std.mem.count(u8, by_lines, "\n") + 1);

    const large = try a.alloc(u8, 51 * 1024);
    defer a.free(large);
    @memset(large, 'a');
    const by_bytes = try apply(a, large, .{});
    defer a.free(by_bytes);
    try std.testing.expectEqual(@as(usize, 50 * 1024), by_bytes.len);
    try std.testing.expect(std.mem.endsWith(u8, by_bytes, notice));
}

test "one-line and zero-sized budgets never exceed their line limits" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("", try apply(a, "many\nlines", .{ .max_lines = 0 }));
    try std.testing.expectEqualStrings("", try apply(a, "large", .{ .max_bytes = 0 }));
    try std.testing.expectEqualStrings("[Tool output truncated]", try apply(a, "one\ntwo", .{ .max_lines = 1 }));
    try std.testing.expectEqualStrings("[Too", try apply(a, "one\ntwo", .{ .max_lines = 1, .max_bytes = 4 }));
}
