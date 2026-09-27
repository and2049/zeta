//! Messages SSE event normalization. Content block indexes become tool call
//! slots; a thinking block's signature is emitted when the block ends, and
//! a redacted thinking block is emitted whole as a signature. All slices
//! emitted to the sink are ephemeral.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const provider_error = @import("../provider_error.zig");
const Sink = plugin.provider.Sink;
const Allocator = std.mem.Allocator;
const Object = std.json.ObjectMap;

pub const State = struct {
    usage: proto.message.Usage = .{},
    stop: ?proto.message.StopReason = null,
    /// Set by `message_stop`.
    finished: bool = false,
    /// Open blocks by index.
    blocks: std.AutoHashMapUnmanaged(u32, Open) = .empty,

    const Open = struct {
        kind: enum { text, thinking, tool, other },
        /// A thinking block's signature so far.
        signature: std.ArrayList(u8) = .empty,
        /// Whether a tool call streamed any input.
        input: bool = false,
    };

    pub fn deinit(st: *State, persistent: Allocator) void {
        var it = st.blocks.valueIterator();
        while (it.next()) |open| open.signature.deinit(persistent);
        st.blocks.deinit(persistent);
    }
};

/// Handles one event's data. `arena` is scratch for this event;
/// `persistent` outlives the stream. `secret` is redacted from errors.
pub fn handle(arena: Allocator, persistent: Allocator, st: *State, data: []const u8, secret: ?[]const u8, sink: Sink) !void {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return error.InvalidChunk;
    const o = object(v) orelse return error.InvalidChunk;
    const ty = string(o, "type") orelse return error.InvalidChunk;
    if (eq(ty, "message_start")) {
        const message = child(o, "message") orelse return;
        if (child(message, "usage")) |u| readUsage(&st.usage, u);
    } else if (eq(ty, "content_block_start")) {
        const index = try blockIndex(o);
        const block = child(o, "content_block") orelse return error.InvalidChunk;
        const kind = string(block, "type") orelse "";
        const slot = try st.blocks.getOrPut(persistent, index);
        if (slot.found_existing) slot.value_ptr.signature.deinit(persistent);
        slot.value_ptr.* = .{ .kind = if (eq(kind, "text")) .text else if (eq(kind, "thinking")) .thinking else if (eq(kind, "tool_use")) .tool else .other };
        if (eq(kind, "tool_use")) {
            try sink.emit(.{ .tool_call_start = .{ .index = index, .id = string(block, "id") orelse "", .name = string(block, "name") orelse "" } });
        } else if (eq(kind, "redacted_thinking")) {
            try sink.emit(.{ .thinking_signature = try std.json.Stringify.valueAlloc(arena, .{ .type = "redacted_thinking", .data = string(block, "data") orelse "" }, .{}) });
        } else if (eq(kind, "text")) {
            if (string(block, "text")) |text| if (text.len > 0) try sink.emit(.{ .text_delta = text });
        }
    } else if (eq(ty, "content_block_delta")) {
        const index = try blockIndex(o);
        const delta = child(o, "delta") orelse return error.InvalidChunk;
        const kind = string(delta, "type") orelse "";
        const open = st.blocks.getPtr(index);
        if (eq(kind, "text_delta")) {
            if (string(delta, "text")) |text| try sink.emit(.{ .text_delta = text });
        } else if (eq(kind, "thinking_delta")) {
            if (string(delta, "thinking")) |text| try sink.emit(.{ .thinking_delta = text });
        } else if (eq(kind, "signature_delta")) {
            if (open) |b| if (string(delta, "signature")) |sig| try b.signature.appendSlice(persistent, sig);
        } else if (eq(kind, "input_json_delta")) {
            if (string(delta, "partial_json")) |args| if (args.len > 0) {
                if (open) |b| b.input = true;
                try sink.emit(.{ .tool_call_delta = .{ .index = index, .arguments = args } });
            };
        }
    } else if (eq(ty, "content_block_stop")) {
        const index = try blockIndex(o);
        var removed = st.blocks.fetchRemove(index) orelse return;
        defer removed.value.signature.deinit(persistent);
        switch (removed.value.kind) {
            .thinking => if (removed.value.signature.items.len > 0) try sink.emit(.{ .thinking_signature = removed.value.signature.items }),
            // A call without parameters streams no input at all.
            .tool => if (!removed.value.input) try sink.emit(.{ .tool_call_delta = .{ .index = index, .arguments = "{}" } }),
            else => {},
        }
    } else if (eq(ty, "message_delta")) {
        if (child(o, "usage")) |u| readUsage(&st.usage, u);
        if (child(o, "delta")) |d| if (string(d, "stop_reason")) |reason| {
            st.stop = stopReason(reason);
        };
    } else if (eq(ty, "message_stop")) {
        try sink.emit(.{ .usage = st.usage });
        st.finished = true;
    } else if (eq(ty, "error")) {
        const e = child(o, "error");
        const kind = if (e) |x| string(x, "type") orelse "" else "";
        var failure = try provider_error.stream(arena, if (e) |x| string(x, "message") orelse kind else "Anthropic response failed without a message", data, secret);
        if (transient(kind)) failure.retryable = true;
        try sink.emit(.{ .failure = failure });
        return error.ProviderError;
    }
}

/// Counts arrive in `message_start` and grow in `message_delta`; a field
/// that is absent keeps its value.
fn readUsage(usage: *proto.message.Usage, u: Object) void {
    if (count(u, "input_tokens")) |n| usage.input = n;
    if (count(u, "output_tokens")) |n| usage.output = n;
    if (count(u, "cache_read_input_tokens")) |n| usage.cacheRead = n;
    if (count(u, "cache_creation_input_tokens")) |n| usage.cacheWrite = n;
}

/// Error types the API documents as passing: a retry may succeed.
fn transient(kind: []const u8) bool {
    for ([_][]const u8{ "overloaded_error", "api_error", "timeout_error", "rate_limit_error" }) |t| if (eq(kind, t)) return true;
    return false;
}

fn stopReason(reason: []const u8) proto.message.StopReason {
    if (eq(reason, "tool_use")) return .tool_use;
    if (eq(reason, "max_tokens") or eq(reason, "model_context_window_exceeded")) return .length;
    return .stop;
}

fn child(o: Object, key: []const u8) ?Object {
    return object(o.get(key) orelse return null);
}
fn object(v: std.json.Value) ?Object {
    return if (v == .object) v.object else null;
}
fn string(o: Object, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn count(o: Object, key: []const u8) ?u64 {
    const v = o.get(key) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}
fn blockIndex(o: Object) !u32 {
    const v = o.get("index") orelse return error.InvalidChunk;
    if (v != .integer) return error.InvalidChunk;
    return std.math.cast(u32, v.integer) orelse error.InvalidChunk;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Recorder = struct {
    out: std.ArrayList(u8) = .empty,
    usage: proto.message.Usage = .{},
    failure: ?plugin.provider.Failure = null,

    fn on(ctx: *anyopaque, e: plugin.provider.Event) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const a = std.testing.allocator;
        switch (e) {
            .text_delta => |t| try self.out.print(a, "text:{s};", .{t}),
            .thinking_delta => |t| try self.out.print(a, "think:{s};", .{t}),
            .thinking_signature => |s| try self.out.print(a, "sig:{s};", .{s}),
            .tool_call_start => |t| try self.out.print(a, "call{d}:{s}:{s};", .{ t.index, t.id, t.name }),
            .tool_call_delta => |t| try self.out.print(a, "args{d}:{s};", .{ t.index, t.arguments }),
            .usage => |u| self.usage = u,
            .failure => |f| self.failure = f,
            .done => {},
        }
    }
};

fn feed(rec: *Recorder, st: *State, lines: []const []const u8) !void {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    for (lines) |line| try handle(scratch.allocator(), std.testing.allocator, st, line, null, .{ .ctx = rec, .onEvent = Recorder.on });
}

test "thinking, text and tool calls stream with usage and stop reason" {
    var rec: Recorder = .{};
    defer rec.out.deinit(std.testing.allocator);
    var st: State = .{};
    defer st.deinit(std.testing.allocator);
    try feed(&rec, &st, &.{
        \\{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":90,"cache_creation_input_tokens":5,"output_tokens":1}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"ab"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"cd"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"xyz"}}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"hi"}}
        ,
        \\{"type":"content_block_stop","index":2}
        ,
        \\{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"t1","name":"read","input":{}}}
        ,
        \\{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}
        ,
        \\{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"1}"}}
        ,
        \\{"type":"content_block_stop","index":3}
        ,
        \\{"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"t2","name":"now","input":{}}}
        ,
        \\{"type":"content_block_stop","index":4}
        ,
        \\{"type":"ping"}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}
        ,
        \\{"type":"message_stop"}
    });
    try std.testing.expectEqualStrings(
        \\think:hmm;sig:abcd;sig:{"type":"redacted_thinking","data":"xyz"};text:hi;call3:t1:read;args3:{"a":;args3:1};call4:t2:now;args4:{};
    , rec.out.items);
    try std.testing.expectEqual(proto.message.StopReason.tool_use, st.stop.?);
    try std.testing.expect(st.finished);
    try std.testing.expectEqual(proto.message.Usage{ .input = 10, .output = 42, .cacheRead = 90, .cacheWrite = 5 }, rec.usage);
}

test "stop reasons and stream errors" {
    try std.testing.expectEqual(proto.message.StopReason.length, stopReason("max_tokens"));
    try std.testing.expectEqual(proto.message.StopReason.stop, stopReason("end_turn"));
    var rec: Recorder = .{};
    defer rec.out.deinit(std.testing.allocator);
    var st: State = .{};
    defer st.deinit(std.testing.allocator);
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectError(error.ProviderError, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    , null, .{ .ctx = &rec, .onEvent = Recorder.on }));
    try std.testing.expectEqualStrings("Overloaded", rec.failure.?.message);
    try std.testing.expect(rec.failure.?.retryable);
    try std.testing.expectError(error.ProviderError, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"error","error":{"type":"timeout_error","message":"bad key sk-ant-secret-1"}}
    , "sk-ant-secret-1", .{ .ctx = &rec, .onEvent = Recorder.on }));
    try std.testing.expectEqualStrings("bad key [redacted]", rec.failure.?.message);
    try std.testing.expect(rec.failure.?.retryable);
    try std.testing.expectError(error.ProviderError, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"error","error":{"type":"invalid_request_error","message":"Please retry later"}}
    , null, .{ .ctx = &rec, .onEvent = Recorder.on }));
    try std.testing.expectError(error.InvalidChunk, handle(scratch.allocator(), std.testing.allocator, &st, "{\"type\":\"content_block_stop\",\"index\":-1}", null, .{ .ctx = &rec, .onEvent = Recorder.on }));
}
