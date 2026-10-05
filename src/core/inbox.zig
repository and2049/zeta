//! A session's inbox: prompts admitted but not yet in the conversation.
//! `steer` items are injected at the next step boundary, `queue` items when
//! the agent would otherwise stop.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Image = @import("proto").attachment.Image;

pub const Delivery = enum { queue, steer };

/// A prompt, a request to compact the history (`text` then holds optional
/// instructions for the summary), or a shell command the user ran while
/// the agent was working (`text` is the command): it joins the
/// conversation at the next step without being asked for.
pub const Kind = enum { prompt, compact, shell };

pub const Item = struct {
    /// `msg_…`, used as the user message id.
    id: []const u8,
    text: []const u8,
    delivery: Delivery,
    images: []const Image = &.{},
    kind: Kind = .prompt,
    /// Shell only: what the command printed, and whether it failed.
    output: []const u8 = "",
    failed: bool = false,
};

pub const Inbox = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Item) = .empty,
    leased: std.ArrayList(Item) = .empty,

    pub fn init(gpa: Allocator, io: Io) Inbox {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(q: *Inbox) void {
        for (q.items.items) |it| q.free(it);
        q.items.deinit(q.gpa);
        for (q.leased.items) |it| q.free(it);
        q.leased.deinit(q.gpa);
    }

    /// Copies `id` and `text`.
    pub fn push(q: *Inbox, id: []const u8, text: []const u8, delivery: Delivery) !void {
        return q.pushWithImages(id, text, delivery, &.{});
    }

    /// Queues a compaction with optional instructions.
    pub fn pushCompact(q: *Inbox, id: []const u8, instructions: []const u8) !void {
        const id_copy = try q.gpa.dupe(u8, id);
        errdefer q.gpa.free(id_copy);
        const text_copy = try q.gpa.dupe(u8, instructions);
        errdefer q.gpa.free(text_copy);
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        try q.items.append(q.gpa, .{ .id = id_copy, .text = text_copy, .delivery = .queue, .kind = .compact });
    }

    /// Admits the result of a command the user ran. Copies the strings.
    pub fn pushShell(q: *Inbox, id: []const u8, command: []const u8, output: []const u8, failed: bool) !void {
        const id_copy = try q.gpa.dupe(u8, id);
        errdefer q.gpa.free(id_copy);
        const text_copy = try q.gpa.dupe(u8, command);
        errdefer q.gpa.free(text_copy);
        const output_copy = try q.gpa.dupe(u8, output);
        errdefer q.gpa.free(output_copy);
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        try q.items.append(q.gpa, .{ .id = id_copy, .text = text_copy, .delivery = .steer, .kind = .shell, .output = output_copy, .failed = failed });
    }

    pub fn pushWithImages(q: *Inbox, id: []const u8, text: []const u8, delivery: Delivery, images: []const Image) !void {
        const id_copy = try q.gpa.dupe(u8, id);
        errdefer q.gpa.free(id_copy);
        const text_copy = try q.gpa.dupe(u8, text);
        errdefer q.gpa.free(text_copy);
        const image_copy = try copyImages(q.gpa, images, true);
        errdefer freeImages(q.gpa, image_copy);
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        try q.items.append(q.gpa, .{ .id = id_copy, .text = text_copy, .delivery = delivery, .images = image_copy });
    }

    /// Leases the oldest item with `delivery` (one item at a time),
    /// copying it into `arena`. A failed allocation leaves it waiting.
    pub fn takeNext(q: *Inbox, arena: Allocator, delivery: Delivery) !?Item {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        for (q.items.items, 0..) |it, i| {
            if (it.delivery != delivery or it.kind == .shell) continue;
            const copy = try copyItem(arena, it);
            try q.leased.append(q.gpa, it);
            _ = q.items.orderedRemove(i);
            return copy;
        }
        return null;
    }

    /// Leases the oldest shell result, like `takeNext`.
    pub fn takeShell(q: *Inbox, arena: Allocator) !?Item {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        for (q.items.items, 0..) |it, i| {
            if (it.kind != .shell) continue;
            const copy = try copyItem(arena, it);
            try q.leased.append(q.gpa, it);
            _ = q.items.orderedRemove(i);
            return copy;
        }
        return null;
    }

    /// A leased prompt remains visible to snapshots until its user message
    /// is durably appended. Runtime holds the state lock for append + ack.
    pub fn ack(q: *Inbox, id: []const u8) void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        for (q.leased.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            const removed = q.leased.orderedRemove(i);
            q.free(removed);
            return;
        }
    }

    /// Only waiting items may be withdrawn. Leased items are already being
    /// promoted to durable messages and must never be silently removed.
    pub fn remove(q: *Inbox, id: []const u8) !void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        for (q.leased.items) |item| if (std.mem.eql(u8, item.id, id)) return error.InboxItemBusy;
        for (q.items.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            q.free(q.items.orderedRemove(i));
            return;
        }
        return error.InboxItemNotFound;
    }

    /// Copies the withdrawn item into `arena` before removing it. A failed
    /// allocation leaves the queue untouched.
    pub fn removeOwned(q: *Inbox, arena: Allocator, id: []const u8) !Item {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        for (q.leased.items) |item| if (std.mem.eql(u8, item.id, id)) return error.InboxItemBusy;
        for (q.items.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            const copy = try copyItem(arena, item);
            q.free(q.items.orderedRemove(i));
            return copy;
        }
        return error.InboxItemNotFound;
    }

    pub fn isEmpty(q: *Inbox) bool {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        return q.items.items.len == 0;
    }

    /// Remove all admitted but unconsumed prompts. Caller serializes this
    /// with worker shutdown via Runtime's stopping flag.
    pub fn clear(q: *Inbox) void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        for (q.items.items) |item| q.free(item);
        q.items.clearRetainingCapacity();
        for (q.leased.items) |item| q.free(item);
        q.leased.clearRetainingCapacity();
    }

    /// Caller owns the returned slice and its strings (prefer an arena).
    pub fn snapshot(q: *Inbox, arena: Allocator) ![]Item {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        const items = try arena.alloc(Item, q.items.items.len + q.leased.items.len);
        for (q.leased.items, items[0..q.leased.items.len]) |source, *out| out.* = try copyItem(arena, source);
        for (q.items.items, items[q.leased.items.len..]) |source, *out| out.* = try copyItem(arena, source);
        return items;
    }

    fn free(q: *Inbox, it: Item) void {
        q.gpa.free(it.id);
        q.gpa.free(it.text);
        if (it.output.len > 0) q.gpa.free(it.output);
        freeImages(q.gpa, it.images);
    }
};

fn copyItem(arena: Allocator, item: Item) !Item {
    return .{ .id = try arena.dupe(u8, item.id), .text = try arena.dupe(u8, item.text), .delivery = item.delivery, .images = try copyImages(arena, item.images, false), .kind = item.kind, .output = if (item.output.len > 0) try arena.dupe(u8, item.output) else "", .failed = item.failed };
}

fn copyImages(a: Allocator, images: []const Image, validate: bool) ![]const Image {
    const result = try a.alloc(Image, images.len);
    var initialized: usize = 0;
    errdefer freeImageContents(a, result[0..initialized]);
    errdefer a.free(result);
    for (images, result) |image, *dest| {
        if (validate) {
            dest.* = try Image.init(a, image.mimeType, image.data);
        } else {
            const mime = try a.dupe(u8, image.mimeType);
            errdefer a.free(mime);
            dest.* = .{ .mimeType = mime, .data = try a.dupe(u8, image.data) };
        }
        initialized += 1;
    }
    return result;
}

fn freeImages(a: Allocator, images: []const Image) void {
    freeImageContents(a, images);
    a.free(images);
}

fn freeImageContents(a: Allocator, images: []const Image) void {
    for (images) |image| {
        a.free(image.mimeType);
        a.free(image.data);
    }
}

test "takeNext leases one item per delivery, oldest first" {
    var q: Inbox = .init(std.testing.allocator, std.testing.io);
    defer q.deinit();
    try q.push("a", "one", .queue);
    try q.push("b", "two", .steer);
    try q.push("c", "three", .queue);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("two", (try q.takeNext(arena.allocator(), .steer)).?.text);
    try std.testing.expect(try q.takeNext(arena.allocator(), .steer) == null);
    try std.testing.expectEqualStrings("one", (try q.takeNext(arena.allocator(), .queue)).?.text);
    try std.testing.expect(!q.isEmpty());
    try std.testing.expectEqualStrings("three", (try q.takeNext(arena.allocator(), .queue)).?.text);
    try std.testing.expect(q.isEmpty());
}

test "shell results wait apart from prompts" {
    var q: Inbox = .init(std.testing.allocator, std.testing.io);
    defer q.deinit();
    try q.pushShell("s", "ls", "a\nb", true);
    try q.push("p", "steer me", .steer);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("steer me", (try q.takeNext(arena.allocator(), .steer)).?.text);
    try std.testing.expect(try q.takeNext(arena.allocator(), .steer) == null);
    const item = (try q.takeShell(arena.allocator())).?;
    try std.testing.expectEqualStrings("ls", item.text);
    try std.testing.expectEqualStrings("a\nb", item.output);
    try std.testing.expect(item.failed);
    try std.testing.expect(try q.takeShell(arena.allocator()) == null);
    q.ack("s");
    q.ack("p");
}

test "leased prompt remains in snapshot until acknowledged" {
    var q: Inbox = .init(std.testing.allocator, std.testing.io);
    defer q.deinit();
    try q.push("msg_a", "admitted", .queue);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try q.takeNext(arena.allocator(), .queue);
    const before = try q.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqualStrings("admitted", before[0].text);
    q.ack("msg_a");
    try std.testing.expectEqual(@as(usize, 0), (try q.snapshot(arena.allocator())).len);
}

test "remove withdraws one waiting item, but not a leased item" {
    var q: Inbox = .init(std.testing.allocator, std.testing.io);
    defer q.deinit();
    try q.push("a", "first", .queue);
    try q.push("b", "second", .queue);
    try q.remove("b");
    try std.testing.expectError(error.InboxItemNotFound, q.remove("b"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try q.takeNext(arena.allocator(), .queue);
    try std.testing.expectError(error.InboxItemBusy, q.remove("a"));
}

test "images are validated, copied through snapshot and returned on removal" {
    var q: Inbox = .init(std.testing.allocator, std.testing.io);
    defer q.deinit();
    try std.testing.expectError(error.InvalidImageMime, q.pushWithImages("bad", "", .queue, &.{.{ .mimeType = "image/svg+xml", .data = "YWJj" }}));
    var encoded = [_]u8{ 'Y', 'W', 'J', 'j' };
    try q.pushWithImages("msg", "look", .queue, &.{.{ .mimeType = "image/png", .data = &encoded }});
    encoded[0] = 'x';
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try q.snapshot(arena.allocator());
    try std.testing.expectEqualStrings("YWJj", snapshot[0].images[0].data);
    const removed = try q.removeOwned(arena.allocator(), "msg");
    try std.testing.expectEqualStrings("YWJj", removed.images[0].data);
    try std.testing.expect(q.isEmpty());
}
