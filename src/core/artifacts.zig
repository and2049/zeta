//! Oversized tool results: the whole text is saved beside the session log
//! (`<location dir>/<session>.artifacts/<call id>.txt`) and the model gets
//! its start and end with the path, which the read tool can page through.
//! A fork gets its own copies.
const std = @import("std");
const plugin = @import("plugin");
const proto = @import("proto");
const storage = @import("session_storage.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The session's artifacts directory, in `arena`.
pub fn dir(arena: Allocator, sessions_dir: []const u8, location: []const u8, session: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}.artifacts", .{ try storage.locationDir(arena, sessions_dir, location), session });
}

/// Writes `text` for call `id` (0600, directory 0700) in a new file named
/// after the call, numbered when that name is taken; the path is in `arena`.
pub fn save(arena: Allocator, io: Io, directory: []const u8, id: []const u8, text: []const u8) ![]const u8 {
    const name = try arena.dupe(u8, id);
    for (name) |*c| if (!std.ascii.isAlphanumeric(c.*) and c.* != '_' and c.* != '-') {
        c.* = '_';
    };
    _ = try Io.Dir.cwd().createDirPathStatus(io, directory, .fromMode(0o700));
    var n: usize = 1;
    const path, const file = while (true) : (n += 1) {
        const path = if (n == 1)
            try std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ directory, name })
        else
            try std.fmt.allocPrint(arena, "{s}/{s}-{d}.txt", .{ directory, name, n });
        const file = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| {
            if (err == error.PathAlreadyExists and n < 1000) continue;
            return err;
        };
        break .{ path, file };
    };
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    // The writer's own error says why (a cancellation among them).
    writer.interface.writeAll(text) catch return writer.err orelse error.WriteFailed;
    writer.interface.flush() catch return writer.err orelse error.WriteFailed;
    return path;
}

/// The start and end of `text` within `limits`, with a note between them
/// saying what was left out and where the whole text is.
pub fn preview(arena: Allocator, text: []const u8, limits: plugin.tool.ResultBudget, path: []const u8) ![]const u8 {
    const total_lines = std.mem.count(u8, text, "\n") + 1;
    const note = try std.fmt.allocPrint(arena, "\n[... output truncated: {d} lines, {d} bytes in total. The full output is in {s}; read it with offset and limit to see the rest ...]\n", .{ total_lines, text.len, path });
    if (limits.max_bytes <= note.len or limits.max_lines < 4) return cut(note[1 .. note.len - 1], limits.max_bytes, limits.max_lines, .front);
    const byte_room = (limits.max_bytes - note.len) / 2;
    const line_room = (limits.max_lines - 3) / 2;
    const head = cut(text, byte_room, line_room, .front);
    const tail = cut(text[head.len..], byte_room, line_room, .back);
    return std.mem.concat(arena, u8, &.{ head, note, tail });
}

/// At most `bytes` bytes and `lines` lines from one end of `text`, ending
/// on a line break when there is one and never inside a UTF-8 sequence.
fn cut(text: []const u8, bytes: usize, lines: usize, from: enum { front, back }) []const u8 {
    if (lines == 0 or bytes == 0) return "";
    switch (from) {
        .front => {
            var end: usize = 0;
            var seen: usize = 0;
            var last_break: ?usize = null;
            while (end < text.len and end < bytes) : (end += 1) {
                if (text[end] == '\n') {
                    seen += 1;
                    last_break = end + 1;
                    if (seen == lines) break;
                }
            }
            if (end < text.len) if (last_break) |b| {
                end = b;
            };
            while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
            return text[0..end];
        },
        .back => {
            var start = text.len;
            var seen: usize = 0;
            var first_break: ?usize = null;
            while (start > 0 and text.len - start < bytes) {
                start -= 1;
                if (text[start] == '\n' and start + 1 < text.len) {
                    seen += 1;
                    first_break = start + 1;
                    if (seen == lines) break;
                }
            }
            if (start > 0) if (first_break) |b| {
                start = b;
            };
            while (start < text.len and (text[start] & 0xc0) == 0x80) start += 1;
            return text[start..];
        },
    }
}

/// Copies every saved result from directory `from` to `to` (a fork's).
pub fn copyAll(io: Io, from: []const u8, to: []const u8) !void {
    var source = Io.Dir.cwd().openDir(io, from, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer source.close(io);
    _ = try Io.Dir.cwd().createDirPathStatus(io, to, .fromMode(0o700));
    var target = try Io.Dir.cwd().openDir(io, to, .{});
    defer target.close(io);
    var it = source.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try source.copyFile(entry.name, target, entry.name, io, .{ .permissions = .fromMode(0o600) });
    }
}

/// `messages` with text that names directory `from` (tool results, and
/// summaries that quote them) pointing at `to` instead; the rest is
/// shared. The copies are in `arena`.
pub fn relink(arena: Allocator, messages: []const proto.Message, from: []const u8, to: []const u8) ![]const proto.Message {
    const out = try arena.dupe(proto.Message, messages);
    for (out) |*m| {
        const content = try arena.dupe(proto.message.Content, m.content);
        for (content) |*c| if (c.* == .text and std.mem.indexOf(u8, c.text, from) != null) {
            c.* = .{ .text = try std.mem.replaceOwned(u8, arena, c.text, from, to) };
        };
        m.content = content;
    }
    return out;
}

/// Whether `path` is inside `root` (both absolute, already resolved).
pub fn inside(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/' or (root.len > 0 and root[root.len - 1] == '/');
}

const testing = std.testing;

test "a preview keeps the start and end within the budget and names the file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..5000) |i| try text.print(a, "line {d}\n", .{i});
    const out = try preview(a, text.items, .{ .max_lines = 100, .max_bytes = 4000 }, "/data/ses.artifacts/call_1.txt");
    try testing.expect(out.len <= 4000);
    try testing.expect(std.mem.count(u8, out, "\n") <= 100);
    try testing.expect(std.mem.startsWith(u8, out, "line 0\n"));
    try testing.expect(std.mem.endsWith(u8, out, "line 4999\n"));
    try testing.expect(std.mem.indexOf(u8, out, "5001 lines") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/data/ses.artifacts/call_1.txt") != null);
}

test "saved artifacts round trip, and paths inside the data directory are recognized" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const directory = try dir(a, base, "/p", "ses_x");
    const path = try save(a, testing.io, directory, "call/1", "everything");
    try testing.expect(std.mem.endsWith(u8, path, "ses_x.artifacts/call_1.txt"));
    try testing.expectEqualStrings("everything", try Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(100)));
    try testing.expect(inside(path, base));
    try testing.expect(!inside("/database", "/data"));
    // Names that clean up the same way do not overwrite each other.
    const again = try save(a, testing.io, directory, "call_1", "more");
    try testing.expect(std.mem.endsWith(u8, again, "ses_x.artifacts/call_1-2.txt"));
    try testing.expectEqualStrings("everything", try Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(100)));

    const fork = try dir(a, base, "/p", "ses_y");
    try copyAll(testing.io, directory, fork);
    try testing.expectEqualStrings("more", try Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/call_1-2.txt", .{fork}), a, .limited(100)));
    try copyAll(testing.io, try dir(a, base, "/p", "ses_none"), fork);
    const relinked = try relink(a, &.{
        .{ .id = "t", .role = .tool_result, .timestamp = 0, .content = &.{.{ .text = try std.fmt.allocPrint(a, "see {s}", .{path}) }} },
        .{ .id = "s", .role = .user, .timestamp = 0, .content = &.{.{ .text = directory }} },
        .{ .id = "o", .role = .user, .timestamp = 0, .content = &.{.{ .text = "other" }} },
    }, directory, fork);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "see {s}/call_1.txt", .{fork}), relinked[0].content[0].text);
    try testing.expectEqualStrings(fork, relinked[1].content[0].text);
    try testing.expectEqualStrings("other", relinked[2].content[0].text);
}

test "a budget too small for the note still holds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "x" ** 500;
    try testing.expect((try preview(arena.allocator(), text, .{ .max_lines = 100, .max_bytes = 32 }, "/p/a.txt")).len <= 32);
    try testing.expectEqualStrings("", try preview(arena.allocator(), text, .{ .max_lines = 0, .max_bytes = 4000 }, "/p/a.txt"));
    try testing.expectEqualStrings("", try preview(arena.allocator(), text, .{ .max_lines = 10, .max_bytes = 0 }, "/p/a.txt"));
}
