//! Owned open questions and the editing state of the question in front.
const std = @import("std");
const client = @import("client");
const Q = client.questions;
const A = std.mem.Allocator;

pub const Answer = struct { action: []const u8, content: ?std.json.Value = null };

pub const Entry = struct {
    arena: std.heap.ArenaAllocator,
    question: Q.Question,
    fields: []const Q.Field = &.{},
    selected: usize = 0,
    text: std.ArrayList(u8) = .empty,
    field_index: usize = 0,
    values: std.json.ObjectMap = .empty,
    invalid: bool = false,

    pub fn allocator(self: *Entry) A {
        return self.arena.allocator();
    }
    pub fn deinit(self: *Entry) void {
        self.arena.deinit();
    }
    pub fn append(self: *Entry, ev: @import("input.zig").Event) !void {
        switch (ev) {
            .text => |cp| {
                var buf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(cp, &buf);
                try self.text.appendSlice(self.allocator(), buf[0..n]);
            },
            .paste => |bytes| try self.text.appendSlice(self.allocator(), bytes),
            .key => |k| if (k == .backspace and self.text.items.len > 0) {
                const width = @import("width.zig");
                var at: usize = 0;
                while (width.clusterEnd(self.text.items, at) < self.text.items.len) at = width.clusterEnd(self.text.items, at);
                self.text.items.len = at;
            },
            else => {},
        }
        self.invalid = false;
    }
};

pub const Queue = struct {
    allocator: A,
    items: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Queue) void {
        for (self.items.items) |*entry| entry.deinit();
        self.items.deinit(self.allocator);
    }
    pub fn clear(self: *Queue) void {
        for (self.items.items) |*entry| entry.deinit();
        self.items.clearRetainingCapacity();
    }
    pub fn add(self: *Queue, data: std.json.Value, envelope_session: ?[]const u8, location: ?[]const u8, session: ?[]const u8, cwd: []const u8) !bool {
        const current = session orelse return false;
        if (envelope_session) |id| {
            if (!std.mem.eql(u8, id, current)) return false;
        } else if (location == null or !std.mem.eql(u8, location.?, cwd)) return false;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const q = Q.Question.parse(a, data) orelse {
            arena.deinit();
            return false;
        };
        for (self.items.items) |item| if (std.mem.eql(u8, item.question.id, q.id)) {
            arena.deinit();
            return false;
        };
        const fs = if (q.schema) |schema| try Q.fields(a, schema) else &.{};
        try self.items.append(self.allocator, .{ .arena = arena, .question = q, .fields = fs });
        return true;
    }
    pub fn remove(self: *Queue, id: []const u8) bool {
        for (self.items.items, 0..) |item, i| if (std.mem.eql(u8, item.question.id, id)) {
            var old = self.items.orderedRemove(i);
            old.deinit();
            return true;
        };
        return false;
    }
};

test "queue filters session and location, deduplicates, and resolves" {
    var queue: Queue = .{ .allocator = std.testing.allocator };
    defer queue.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"id":"q","kind":"confirm","source":"hook","message":"Go?"}
    , .{});
    try std.testing.expect(!try queue.add(value, "other", "/tmp", "mine", "/tmp"));
    try std.testing.expect(!try queue.add(value, null, "/else", "mine", "/tmp"));
    try std.testing.expect(try queue.add(value, null, "/tmp", "mine", "/tmp"));
    try std.testing.expect(!try queue.add(value, "mine", null, "mine", "/tmp"));
    const next = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"id":"next","kind":"input","source":"plugin","message":"Name?"}
    , .{});
    try std.testing.expect(try queue.add(next, "mine", null, "mine", "/tmp"));
    try std.testing.expect(queue.remove("q"));
    try std.testing.expectEqualStrings("next", queue.items.items[0].question.id);
    try std.testing.expect(queue.remove("next"));
    try std.testing.expectEqual(@as(usize, 0), queue.items.items.len);
}
