//! Bounded previews of file changes. Text returned to the model retains its
//! existing budget; metadata never duplicates whole large files.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");

pub const max_bytes = (plugin.tool.ResultBudget{}).max_bytes;

pub fn change(path: []const u8, before: []const u8, after: []const u8) proto.message.FileChange {
    const half = max_bytes / 2;
    return .{
        .path = path,
        .before = prefix(before, half),
        .after = prefix(after, half),
        .truncated = before.len > half or after.len > half,
    };
}

pub fn prefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

/// Only read a bounded preview, including an extra byte for truncation.
/// Missing files have no old content; other I/O failures propagate.
pub fn previous(arena: std.mem.Allocator, io: std.Io, path: []const u8) !struct { text: []const u8, truncated: bool } {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .text = "", .truncated = false },
        else => return err,
    };
    defer file.close(io);
    const buffer = try arena.alloc(u8, max_bytes / 2 + 1);
    const n = try file.readPositionalAll(io, buffer, 0);
    // The extra byte lets `prefix` see whether the cut splits a character.
    return .{ .text = prefix(buffer[0..n], max_bytes / 2), .truncated = n > max_bytes / 2 };
}

test "a preview of a large file never ends inside a character" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // One ASCII byte shifts every two-byte character across the cut.
    const content = try std.mem.concat(a, u8, &.{ "x", "é" ** (max_bytes / 2) });
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = content });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ buf[0..try tmp.dir.realPath(io, &buf)], "big.txt" });
    const preview = try previous(a, io, path);
    try std.testing.expect(preview.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview.text));
    try std.testing.expect(std.unicode.utf8ValidateSlice(change("big.txt", preview.text, content).after));
}
