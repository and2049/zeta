//! Multiline UTF-8 editor. Cursor is a grapheme boundary, not a byte index
//! within a displayed emoji or combining sequence.
const std = @import("std");
const input = @import("input.zig");
const width = @import("width.zig");

pub const Editor = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    queued: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Editor) void {
        self.bytes.deinit(self.allocator);
        for (self.queued.items) |draft| self.allocator.free(draft);
        self.queued.deinit(self.allocator);
    }
    pub fn text(self: *const Editor) []const u8 {
        return self.bytes.items;
    }
    pub fn clear(self: *Editor) void {
        self.bytes.clearRetainingCapacity();
        self.cursor = 0;
    }
    /// The returned submission belongs to caller; null for an empty draft.
    pub fn submit(self: *Editor) !?[]u8 {
        if (std.mem.trim(u8, self.text(), " \t\r\n").len == 0) return null;
        const draft = try self.allocator.dupe(u8, self.text());
        self.clear();
        return draft;
    }
    /// Alt+Enter queues a draft without submitting it to the caller.
    pub fn queue(self: *Editor) !void {
        const draft = (try self.submit()) orelse return;
        errdefer self.allocator.free(draft);
        try self.queued.append(self.allocator, draft);
    }
    /// Caller owns the returned queued draft (or null).
    pub fn popQueued(self: *Editor) ?[]u8 {
        if (self.queued.items.len == 0) return null;
        return self.queued.orderedRemove(0);
    }
    pub fn insert(self: *Editor, text_to_insert: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text_to_insert)) return error.InvalidUtf8;
        const old = self.bytes.items.len;
        try self.bytes.resize(self.allocator, old + text_to_insert.len);
        std.mem.copyBackwards(u8, self.bytes.items[self.cursor + text_to_insert.len ..], self.bytes.items[self.cursor..old]);
        @memcpy(self.bytes.items[self.cursor..][0..text_to_insert.len], text_to_insert);
        self.cursor += text_to_insert.len;
    }
    fn prev(self: *const Editor, from: usize) usize {
        if (from == 0) return 0;
        var at: usize = 0;
        while (at < from) {
            const end = width.clusterEnd(self.text(), at);
            if (end >= from) return at;
            at = end;
        }
        return at;
    }
    fn nextByte(self: *const Editor, from: usize) usize {
        return width.clusterEnd(self.text(), from);
    }
    fn erase(self: *Editor, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.bytes.items[start..], self.bytes.items[end..]);
        self.bytes.items.len -= end - start;
        self.cursor = start;
    }
    fn space(b: u8) bool {
        return b == ' ' or b == '\t' or b == '\n';
    }
    pub fn apply(self: *Editor, event: input.Event) !void {
        switch (event) {
            .text => |cp| {
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(cp, &buf);
                try self.insert(buf[0..len]);
            },
            .paste => |p| try self.insert(p),
            .key => |key| switch (key) {
                .newline => try self.insert("\n"),
                .tab => try self.insert("\t"),
                .clear => self.clear(),
                .queue => try self.queue(),
                .left => self.cursor = self.prev(self.cursor),
                .right => self.cursor = self.nextByte(self.cursor),
                .backspace => self.erase(self.prev(self.cursor), self.cursor),
                .delete => self.erase(self.cursor, self.nextByte(self.cursor)),
                .home => {
                    while (self.cursor > 0 and self.bytes.items[self.cursor - 1] != '\n') self.cursor = self.prev(self.cursor);
                },
                .end => {
                    while (self.cursor < self.bytes.items.len and self.bytes.items[self.cursor] != '\n') self.cursor = self.nextByte(self.cursor);
                },
                .word_left, .word_backspace => {
                    var i = self.cursor;
                    while (i > 0 and space(self.bytes.items[i - 1])) i = self.prev(i);
                    while (i > 0 and !space(self.bytes.items[i - 1])) i = self.prev(i);
                    if (key == .word_left) self.cursor = i else self.erase(i, self.cursor);
                },
                .word_right, .word_delete => {
                    var i = self.cursor;
                    while (i < self.bytes.items.len and space(self.bytes.items[i])) i = self.nextByte(i);
                    while (i < self.bytes.items.len and !space(self.bytes.items[i])) i = self.nextByte(i);
                    if (key == .word_right) self.cursor = i else self.erase(self.cursor, i);
                },
                .up, .down => {
                    const pos = self.position();
                    const target = if (key == .up) (if (pos.row == 0) return else pos.row - 1) else pos.row + 1;
                    var row: usize = 0;
                    var start: usize = 0;
                    for (self.bytes.items, 0..) |b, i| if (b == '\n') {
                        if (row == target) break;
                        row += 1;
                        start = i + 1;
                    };
                    if (row != target) return;
                    var i = start;
                    while (i < self.bytes.items.len and self.bytes.items[i] != '\n') {
                        const end = self.nextByte(i);
                        if (width.displayWidth(self.bytes.items[start..end]) > pos.column) break;
                        i = end;
                    }
                    self.cursor = i;
                },
                else => {}, // enter/quit/escape are application actions
            },
            else => {},
        }
    }
    pub const Position = struct { row: usize, column: usize };
    pub fn position(self: *const Editor) Position {
        var row: usize = 0;
        var start: usize = 0;
        for (self.bytes.items[0..self.cursor], 0..) |b, i| if (b == '\n') {
            row += 1;
            start = i + 1;
        };
        return .{ .row = row, .column = width.displayWidth(self.bytes.items[start..self.cursor]) };
    }
};

test "multiline unicode cursor edits and queue" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    try e.insert("a界\nhello world");
    try e.apply(.{ .key = .home });
    try e.apply(.{ .key = .word_delete });
    try std.testing.expectEqualStrings("a界\n world", e.text());
    try e.apply(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), e.position().row);
    try e.apply(.{ .key = .backspace });
    try e.queue();
    const draft = e.popQueued().?;
    defer std.testing.allocator.free(draft);
    try std.testing.expectEqualStrings("a界\n world", draft);
    try std.testing.expectEqualStrings("", e.text());
}

test "grapheme movement and deletion preserve joined emoji and combining marks" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    try e.insert("e\xcc\x81👩🏽‍💻🇺🇸\n👨‍👩‍👧x");
    try e.apply(.{ .key = .home });
    try e.apply(.{ .key = .right });
    try std.testing.expectEqual(@as(usize, 2), e.position().column);
    try e.apply(.{ .key = .backspace });
    try std.testing.expectEqualStrings("e\xcc\x81👩🏽‍💻🇺🇸\nx", e.text());
    try e.apply(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), e.position().row);
    try e.apply(.{ .key = .right });
    try std.testing.expectEqual(@as(usize, 1), e.position().column);
    try e.apply(.{ .key = .delete });
    try std.testing.expectEqualStrings("e\xcc\x81🇺🇸\nx", e.text());
    try e.apply(.{ .key = .backspace });
    try std.testing.expectEqualStrings("🇺🇸\nx", e.text());
}
