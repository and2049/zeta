//! One session projection. The arena owns the entire hydrated view until switch/deinit.
const std = @import("std");
const proto = @import("proto");
const api = @import("session_api.zig");
const A = std.mem.Allocator;

pub const State = struct {
    gpa: A,
    arena: std.heap.ArenaAllocator,
    selected: ?[]const u8 = null,
    snapshot: ?api.Snapshot = null,
    seq: u64 = 0,
    hydrated: bool = false,
    pending: std.ArrayList([]u8) = .empty,
    pending_bytes: usize = 0,
    /// Draft blocks and growing text live outside the snapshot arena. Slices in
    /// `snapshot.inflight` remain valid until the next mutating State call.
    draft_blocks: std.ArrayList(proto.message.Content) = .empty,
    draft_buffers: std.ArrayList(std.ArrayList(u8)) = .empty,
    /// A bounded pre-hydration queue. Overflow requires a fresh subscription.
    max_pending: usize = 32 * 1024 * 1024,

    pub fn init(gpa: A) State {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }
    pub fn deinit(s: *State) void {
        s.clear();
        s.draft_blocks.deinit(s.gpa);
        s.draft_buffers.deinit(s.gpa);
        s.arena.deinit();
    }
    fn clearDraft(s: *State) void {
        for (s.draft_buffers.items) |*buffer| buffer.deinit(s.gpa);
        s.draft_buffers.clearRetainingCapacity();
        s.draft_blocks.clearRetainingCapacity();
    }
    fn clear(s: *State) void {
        s.clearDraft();
        for (s.pending.items) |raw| s.gpa.free(raw);
        s.pending.deinit(s.gpa);
        s.pending = .empty;
        s.pending_bytes = 0;
        _ = s.arena.reset(.free_all);
        s.selected = null;
        s.snapshot = null;
        s.seq = 0;
        s.hydrated = false;
    }
    pub fn select(s: *State, id: []const u8) !void {
        // `id` is allowed to alias `selected`, which clear() releases.
        const copy = try s.gpa.dupe(u8, id);
        defer s.gpa.free(copy);
        s.clear();
        s.selected = try s.arena.allocator().dupe(u8, copy);
    }
    /// On each new SSE connection, discard the prior projection and re-fetch.
    pub fn reconnect(s: *State) !void {
        const id = s.selected orelse return;
        const copy = try s.gpa.dupe(u8, id);
        defer s.gpa.free(copy);
        try s.select(copy);
    }
    /// Accept raw envelopes while GET is in flight, then replay strictly after revision.
    pub fn enqueue(s: *State, raw: []const u8) !void {
        var temp: std.heap.ArenaAllocator = .init(s.gpa);
        defer temp.deinit();
        const event = try proto.event.Decoded.parse(temp.allocator(), raw);
        if (s.selected == null or event.session == null or !std.mem.eql(u8, s.selected.?, event.session.?)) return;
        if (s.hydrated) return s.apply(if (eq(event.type, proto.event.types.message_part_delta)) event else try proto.event.Decoded.parse(s.arena.allocator(), raw));
        if (s.pending_bytes + raw.len > s.max_pending) return error.ResyncRequired;
        try s.pending.append(s.gpa, try s.gpa.dupe(u8, raw));
        s.pending_bytes += raw.len;
    }
    pub fn hydrate(s: *State, raw: []const u8) !void {
        const view = try api.decodeSnapshot(s.arena.allocator(), raw);
        if (s.selected == null or !std.mem.eql(u8, s.selected.?, view.info.id)) return error.WrongSession;
        s.clearDraft();
        s.snapshot = view;
        s.seq = view.revision;
        s.hydrated = true;
        for (s.pending.items) |item| {
            var temp: std.heap.ArenaAllocator = .init(s.gpa);
            defer temp.deinit();
            const event = try proto.event.Decoded.parse(temp.allocator(), item);
            try s.apply(if (eq(event.type, proto.event.types.message_part_delta)) event else try proto.event.Decoded.parse(s.arena.allocator(), item));
        }
        for (s.pending.items) |item| s.gpa.free(item);
        s.pending.clearRetainingCapacity();
        s.pending_bytes = 0;
    }
    pub fn mergePage(s: *State, page: api.Page) !void {
        const view = if (s.hydrated) &(s.snapshot orelse return error.NotHydrated) else return error.NotHydrated;
        const a = s.arena.allocator();
        var out: std.ArrayList(proto.Message) = .empty;
        for (page.messages) |m| {
            if (!contains(view.messages, m.id) and !contains(out.items, m.id)) try out.append(a, try cloneMessage(a, m));
        }
        try out.appendSlice(a, view.messages);
        view.messages = out.items;
        view.nextBefore = if (page.nextBefore) |cursor| try a.dupe(u8, cursor) else null;
    }
    fn apply(s: *State, e: proto.event.Decoded) !void {
        if (e.seq <= s.seq) return;
        if (s.selected == null or e.session == null or !std.mem.eql(u8, s.selected.?, e.session.?)) return;
        const v = &(s.snapshot orelse return error.NotHydrated);
        const a = s.arena.allocator();
        const data = if (e.data == .object) e.data.object else return;
        const t = e.type;
        if (eq(t, proto.event.types.session_inbox_updated)) {
            v.inbox = try std.json.parseFromValueLeaky([]const api.Inbox, a, data.get("inbox") orelse return, .{ .ignore_unknown_fields = true });
        } else if (eq(t, proto.event.types.message_start) or eq(t, proto.event.types.message_end)) {
            const m = try proto.Message.parse(a, data.get("message") orelse return);
            if (eq(t, proto.event.types.message_start) and m.role == .assistant) {
                s.clearDraft();
                v.inflight = m;
            } else {
                if (eq(t, proto.event.types.message_end)) {
                    var list: std.ArrayList(proto.Message) = .empty;
                    for (v.messages) |old| if (!eq(old.id, m.id)) try list.append(a, old);
                    try list.append(a, m);
                    v.messages = list.items;
                    if (v.inflight) |draft| if (eq(draft.id, m.id)) {
                        v.inflight = null;
                        s.clearDraft();
                    };
                }
            }
        } else if (eq(t, proto.event.types.message_part_delta)) {
            if (v.inflight) |*draft| {
                if (string(data, "messageId")) |id| if (eq(draft.id, id)) {
                    const index_value = data.get("index") orelse return;
                    if (index_value != .integer or index_value.integer < 0) return;
                    const index: usize = @intCast(index_value.integer);
                    const kind = string(data, "kind") orelse return;
                    const delta = string(data, "delta") orelse return;
                    if (index > draft.content.len or index > 1024) return error.ResyncRequired;
                    try s.appendDraft(draft, index, kind, delta);
                };
            }
        } else if (eq(t, proto.event.types.shell_started)) {
            v.shell = try std.json.parseFromValueLeaky(api.Shell, a, e.data, .{ .ignore_unknown_fields = true });
        } else if (eq(t, proto.event.types.shell_ended)) {
            v.shell = null;
        } else if (eq(t, proto.event.types.session_idle) or eq(t, proto.event.types.agent_end)) {
            v.running = false;
        } else if (eq(t, proto.event.types.agent_start)) {
            v.running = true;
        } else if (eq(t, proto.event.types.message_cancelled)) {
            if (v.inflight) |draft| if (string(data, "messageId")) |id| if (eq(draft.id, id)) {
                v.inflight = null;
                s.clearDraft();
            };
        } else if (eq(t, proto.event.types.session_deleted)) {
            s.clearDraft();
            s.snapshot = null;
            s.hydrated = false;
        } else if (eq(t, proto.event.types.session_moved)) {
            if (string(data, "location")) |location| v.info.location = location;
        } else if (eq(t, proto.event.types.session_created) or eq(t, proto.event.types.session_updated)) {
            if (data.get("session")) |info| v.info = try std.json.parseFromValueLeaky(api.Info, a, info, .{ .ignore_unknown_fields = true });
            if (eq(t, proto.event.types.session_updated)) {
                if (data.get("model")) |model| v.options.model = if (model == .string) model.string else null;
                if (data.get("thinking")) |thinking| v.options.thinking = if (thinking == .string) thinking.string else null;
            }
        }
        s.seq = e.seq;
    }
    fn appendDraft(s: *State, draft: *proto.Message, index: usize, kind: []const u8, delta: []const u8) !void {
        // Initialize from the hydrated draft once; subsequent deltas use
        // geometric ArrayList growth, never retaining cumulative copies.
        if (s.draft_blocks.items.len == 0 and draft.content.len > 0) {
            for (draft.content) |block| {
                try s.draft_blocks.append(s.gpa, block);
                try s.draft_buffers.append(s.gpa, .empty);
            }
        }
        if (index > s.draft_blocks.items.len) return error.ResyncRequired;
        if (index == s.draft_blocks.items.len) {
            const block: proto.message.Content = if (eq(kind, "text")) .{ .text = "" } else if (eq(kind, "thinking")) .{ .thinking = .{ .text = "" } } else if (eq(kind, "toolCall")) .{ .tool_call = .{ .id = "", .name = try s.arena.allocator().dupe(u8, delta), .arguments = "" } } else return error.ResyncRequired;
            try s.draft_blocks.append(s.gpa, block);
            try s.draft_buffers.append(s.gpa, .empty);
        }
        const block = &s.draft_blocks.items[index];
        const bytes: ?[]const u8 = if (eq(kind, "text") and block.* == .text) block.text else if (eq(kind, "thinking") and block.* == .thinking) block.thinking.text else if (eq(kind, "toolCallArguments") and block.* == .tool_call) block.tool_call.arguments else null;
        if (bytes) |existing| {
            const buffer = &s.draft_buffers.items[index];
            if (buffer.items.len == 0 and existing.len > 0) try buffer.appendSlice(s.gpa, existing);
            try buffer.appendSlice(s.gpa, delta);
            if (block.* == .text) block.text = buffer.items else if (block.* == .thinking) block.thinking.text = buffer.items else block.tool_call.arguments = buffer.items;
        } else if (eq(kind, "toolCall") and block.* == .tool_call) {
            // A repeated start carries a name that arrived late.
            if (block.tool_call.name.len == 0 and delta.len > 0) block.tool_call.name = try s.arena.allocator().dupe(u8, delta);
        } else return error.ResyncRequired;
        draft.content = s.draft_blocks.items;
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn string(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn contains(messages: []const proto.Message, id: []const u8) bool {
    for (messages) |m| if (eq(m.id, id)) return true;
    return false;
}
fn cloneMessage(a: A, m: proto.Message) !proto.Message {
    const raw = try std.json.Stringify.valueAlloc(a, m, .{});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
    return proto.Message.parse(a, v);
}

test "hydrate replays only newer frames and isolates session switch" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try s.select("one");
    try s.enqueue(
        \\{"seq":5,"type":"message.part.delta","session":"one","time":1,"data":{"messageId":"m","index":0,"kind":"text","delta":"old"}}
    );
    try s.enqueue(
        \\{"seq":7,"type":"message.part.delta","session":"one","time":1,"data":{"messageId":"m","index":0,"kind":"text","delta":"!"}}
    );
    try s.enqueue(
        \\{"seq":8,"type":"message.end","session":"two","time":1,"data":{}}
    );
    try s.hydrate(
        \\{"revision":6,"info":{"id":"one","location":"/a","created":1},"options":{},"running":true,"inbox":[],"messages":[],"inflight":{"id":"m","role":"assistant","content":[{"type":"text","text":"hi"}],"timestamp":1},"nextBefore":null}
    );
    try std.testing.expectEqualStrings("hi!", s.snapshot.?.inflight.?.content[0].text);
    try std.testing.expectEqual(@as(u64, 7), s.seq);
    try s.select("two");
    try std.testing.expect(s.snapshot == null);
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "page merge deduplicates overlap" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try s.select("one");
    try s.hydrate(
        \\{"revision":1,"info":{"id":"one","location":"/a","created":1},"options":{},"running":false,"inbox":[],"messages":[{"id":"new","role":"user","content":[],"timestamp":3}],"inflight":null,"nextBefore":"new"}
    );
    const a = s.arena.allocator();
    try s.mergePage(.{ .messages = &.{
        .{ .id = "old", .role = .user, .content = &.{}, .timestamp = 1 },
        .{ .id = "new", .role = .user, .content = &.{}, .timestamp = 3 },
    }, .nextBefore = null });
    try std.testing.expectEqual(@as(usize, 2), s.snapshot.?.messages.len);
    try std.testing.expectEqualStrings("old", s.snapshot.?.messages[0].id);
    _ = a;
}

test "hydration and inbox updates retain images and message file changes" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try s.select("one");
    try s.hydrate(
        \\{"revision":1,"info":{"id":"one","location":"/a","created":1},"options":{},"running":true,"inbox":[{"id":"q","text":"show","delivery":"queue","images":[{"mimeType":"image/png","data":"YWJj"}]}],"messages":[{"id":"m","role":"assistant","content":[{"type":"image","mimeType":"image/png","data":"YWJj"}],"timestamp":1,"changes":[{"path":"file","before":"a","after":"b"}]}],"inflight":null,"nextBefore":null}
    );
    try std.testing.expectEqualStrings("YWJj", s.snapshot.?.inbox[0].images[0].data);
    try std.testing.expectEqualStrings("b", s.snapshot.?.messages[0].changes[0].after);
    try std.testing.expectEqualStrings("image/png", s.snapshot.?.messages[0].content[0].image.mimeType);
    try s.enqueue(
        \\{"seq":2,"type":"session.inbox.updated","session":"one","time":1,"data":{"inbox":[{"id":"q2","text":"edit","delivery":"steer","images":[{"mimeType":"image/png","data":"YWJj"}]}]}}
    );
    try std.testing.expectEqualStrings("q2", s.snapshot.?.inbox[0].id);
    try std.testing.expectEqualStrings("YWJj", s.snapshot.?.inbox[0].images[0].data);
}

test "tool call deltas extend an inflight draft" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try s.select("one");
    try s.hydrate(
        \\{"revision":1,"info":{"id":"one","location":"/a","created":1},"options":{},"running":true,"inbox":[],"messages":[],"inflight":{"id":"m","role":"assistant","content":[],"timestamp":1},"nextBefore":null}
    );
    try s.enqueue(
        \\{"seq":2,"type":"message.part.delta","session":"one","time":1,"data":{"messageId":"m","index":0,"kind":"toolCall","delta":"read"}}
    );
    try s.enqueue(
        \\{"seq":3,"type":"message.part.delta","session":"one","time":1,"data":{"messageId":"m","index":0,"kind":"toolCallArguments","delta":"{\"path\":1}"}}
    );
    try std.testing.expectEqualStrings("read", s.snapshot.?.inflight.?.content[0].tool_call.name);
    try std.testing.expectEqualStrings("{\"path\":1}", s.snapshot.?.inflight.?.content[0].tool_call.arguments);
}

test "session.updated changes metadata without touching history or draft" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try s.select("one");
    try s.hydrate(
        \\{"revision":1,"info":{"id":"one","location":"/a","created":1},"options":{},"running":true,"inbox":[],"messages":[{"id":"old","role":"user","content":[],"timestamp":1}],"inflight":{"id":"m","role":"assistant","content":[{"type":"text","text":"partial"}],"timestamp":2},"nextBefore":"old"}
    );
    try s.enqueue(
        \\{"seq":2,"type":"session.updated","session":"one","time":2,"data":{"session":{"id":"one","location":"/a","created":1,"title":"Hello"},"model":"fake/new","thinking":"high"}}
    );
    try std.testing.expectEqualStrings("Hello", s.snapshot.?.info.title.?);
    try std.testing.expectEqualStrings("fake/new", s.snapshot.?.options.model.?);
    try std.testing.expectEqualStrings("high", s.snapshot.?.options.thinking.?);
    try s.enqueue(
        \\{"seq":3,"type":"session.updated","session":"one","time":3,"data":{"thinking":null}}
    );
    try std.testing.expect(s.snapshot.?.options.thinking == null);
    try std.testing.expectEqualStrings("fake/new", s.snapshot.?.options.model.?);
    try std.testing.expectEqualStrings("old", s.snapshot.?.messages[0].id);
    try std.testing.expectEqualStrings("partial", s.snapshot.?.inflight.?.content[0].text);
    try std.testing.expectEqualStrings("old", s.snapshot.?.nextBefore.?);
}

test "thousands of streamed tokens retain linear draft storage" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try s.select("one");
    try s.hydrate(
        \\{"revision":1,"info":{"id":"one","location":"/a","created":1},"options":{},"running":true,"inbox":[],"messages":[],"inflight":{"id":"m","role":"assistant","content":[],"timestamp":1},"nextBefore":null}
    );
    for (0..6000) |i| {
        const frame = try std.fmt.allocPrint(std.testing.allocator, "{{\"seq\":{d},\"type\":\"message.part.delta\",\"session\":\"one\",\"time\":1,\"data\":{{\"messageId\":\"m\",\"index\":0,\"kind\":\"text\",\"delta\":\"word\"}}}}", .{i + 2});
        defer std.testing.allocator.free(frame);
        try s.enqueue(frame);
    }
    try std.testing.expectEqual(@as(usize, 24_000), s.snapshot.?.inflight.?.content[0].text.len);
    // The old cumulative-concat reducer retained ~72 MiB for this stream.
    // Here the arena stays essentially constant and the growing buffer uses
    // geometric capacity, at most a small multiple of the final text.
    try std.testing.expect(s.arena.queryCapacity() < 128 * 1024);
    try std.testing.expect(s.draft_buffers.items[0].capacity < 128 * 1024);
    try std.testing.expect(s.draft_blocks.capacity < 1024);
    try s.select(s.selected.?);
    try std.testing.expectEqualStrings("one", s.selected.?);
    try std.testing.expectEqual(@as(usize, 0), s.draft_buffers.items.len);
}

test "pre-hydration queue permits a maximum-size SSE frame" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(s.max_pending >= proto.sse.Decoder.init(std.testing.allocator).max_data);
    try s.select("one");
    // An image field can be much larger than the old 2 MiB queue limit.
    const prefix = "{\"seq\":1,\"type\":\"session.inbox.updated\",\"session\":\"one\",\"time\":1,\"data\":{\"inbox\":[{\"id\":\"q\",\"text\":\"x\",\"delivery\":\"queue\",\"images\":[{\"mimeType\":\"image/png\",\"data\":\"";
    const suffix = "\"}]}]}}";
    const bytes = try std.testing.allocator.alloc(u8, prefix.len + 4 * 1024 * 1024 + suffix.len);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..prefix.len], prefix);
    @memset(bytes[prefix.len..][0 .. 4 * 1024 * 1024], 'A');
    @memcpy(bytes[bytes.len - suffix.len ..], suffix);
    try s.enqueue(bytes);
    try std.testing.expectEqual(@as(usize, 1), s.pending.items.len);
}
