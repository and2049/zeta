//! Responses SSE event normalization. All slices emitted to Sink are ephemeral.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Sink = plugin.provider.Sink;
const provider_error = @import("../provider_error.zig");
const Object = std.json.ObjectMap;

pub const State = struct {
    finish: ?proto.message.StopReason = null,
    calls: std.AutoHashMapUnmanaged(u32, usize) = .empty, // output index -> argument bytes emitted
    saw_call: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.calls.deinit(allocator);
    }
};

pub fn handle(arena: std.mem.Allocator, persistent: std.mem.Allocator, st: *State, data: []const u8, sink: Sink) !void {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return error.InvalidChunk;
    const o = object(v) orelse return error.InvalidChunk;
    const ty = string(o, "type") orelse return error.InvalidChunk;
    if (eq(ty, "error") or eq(ty, "response.failed")) {
        const e = if (o.get("error")) |x| object(x) else null;
        const r = if (o.get("response")) |x| object(x) else null;
        const nested = if (r) |x| if (x.get("error")) |y| object(y) else null else null;
        const message = if (e orelse nested) |err| string(err, "message") else null;
        var failure = try provider_error.stream(arena, message orelse "Codex response failed without a message", data, null);
        if (e orelse nested) |err| if (string(err, "code")) |code| if (provider_error.overflow(code) and !provider_error.rateLimited(data)) {
            failure = .{ .message = failure.message, .overflow = true };
        };
        try sink.emit(.{ .failure = failure });
        return error.ProviderError;
    }
    if (eq(ty, "response.output_text.delta")) {
        if (string(o, "delta")) |text| try sink.emit(.{ .text_delta = text });
    } else if (eq(ty, "response.reasoning_summary_text.delta") or eq(ty, "response.reasoning_text.delta") or eq(ty, "response.reasoning.delta")) {
        if (string(o, "delta")) |text| try sink.emit(.{ .thinking_delta = text });
    } else if (eq(ty, "response.output_item.added") or eq(ty, "response.output_item.done")) {
        const item = if (o.get("item")) |x| object(x) else null;
        // A finished reasoning item carries the encrypted reasoning; replaying
        // the item lets the next request continue from it.
        if (item) |i| if (eq(ty, "response.output_item.done") and eq(string(i, "type") orelse "", "reasoning")) {
            if (string(i, "encrypted_content") != null) {
                try sink.emit(.{ .thinking_signature = try std.json.Stringify.valueAlloc(arena, o.get("item").?, .{}) });
            }
        };
        if (item) |i| if (eq(string(i, "type") orelse "", "function_call")) {
            const index = try outputIndex(o);
            const emitted = try st.calls.getOrPut(persistent, index);
            if (!emitted.found_existing) emitted.value_ptr.* = 0;
            st.saw_call = true;
            // Both events may carry the identity; the assembler keeps the
            // first non-empty id and name.
            try sink.emit(.{ .tool_call_start = .{ .index = index, .id = string(i, "call_id") orelse "", .name = string(i, "name") orelse "" } });
            // `done` carries the complete arguments. Emit whatever the
            // deltas did not already deliver.
            if (eq(ty, "response.output_item.done")) if (string(i, "arguments")) |args| {
                const sent = emitted.value_ptr.*;
                if (args.len > sent) {
                    try sink.emit(.{ .tool_call_delta = .{ .index = index, .arguments = args[sent..] } });
                    emitted.value_ptr.* = args.len;
                }
            };
        };
    } else if (eq(ty, "response.function_call_arguments.delta")) {
        const index = try outputIndex(o);
        if (string(o, "delta")) |args| if (args.len > 0) {
            const emitted = try st.calls.getOrPut(persistent, index);
            if (!emitted.found_existing) emitted.value_ptr.* = 0;
            st.saw_call = true;
            try sink.emit(.{ .tool_call_delta = .{ .index = index, .arguments = args } });
            emitted.value_ptr.* += args.len;
        };
    } else if (eq(ty, "response.completed") or eq(ty, "response.incomplete")) {
        const resp = if (o.get("response")) |x| object(x) else null;
        if (resp) |r| {
            if (r.get("usage")) |uv| if (object(uv)) |u| {
                const details = if (u.get("input_tokens_details")) |x| object(x) else null;
                const cached = if (details) |d| number(d, "cached_tokens") else 0;
                try sink.emit(.{ .usage = .{ .input = number(u, "input_tokens") -| cached, .output = number(u, "output_tokens"), .cacheRead = cached } });
            };
        }
        if (eq(ty, "response.incomplete")) {
            const details = if (resp) |r| if (r.get("incomplete_details")) |x| object(x) else null else null;
            const reason = if (details) |d| string(d, "reason") else null;
            if (reason == null or !eq(reason.?, "max_output_tokens")) {
                try sink.emit(.{ .failure = .{ .message = if (reason) |r| r else "Codex response incomplete without reason" } });
                return error.IncompleteResponse;
            }
            st.finish = .length;
        } else st.finish = if (st.saw_call) .tool_use else .stop;
    }
}

fn object(v: std.json.Value) ?Object {
    return if (v == .object) v.object else null;
}
fn string(o: Object, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn number(o: Object, key: []const u8) u64 {
    const v = o.get(key) orelse return 0;
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
}
fn outputIndex(o: Object) !u32 {
    const v = o.get("output_index") orelse return 0;
    if (v != .integer) return error.InvalidChunk;
    return std.math.cast(u32, v.integer) orelse error.InvalidChunk;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "streaming text, reasoning, function call, usage and finish" {
    const Rec = struct {
        out: std.ArrayList(u8) = .empty,
        fn on(ctx: *anyopaque, e: plugin.provider.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const part = switch (e) {
                .text_delta => "text",
                .thinking_delta => "think",
                .thinking_signature => |sig| if (std.mem.indexOf(u8, sig, "\"encrypted_content\":\"enc\"") != null) "sig" else "badsig",
                .tool_call_start => "call",
                .tool_call_delta => "args",
                .usage => "usage",
                else => "unexpected",
            };
            try self.out.appendSlice(std.testing.allocator, part);
            try self.out.append(std.testing.allocator, ';');
        }
    };
    var rec: Rec = .{};
    defer rec.out.deinit(std.testing.allocator);
    var st: State = .{};
    defer st.deinit(std.testing.allocator);
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const sink: Sink = .{ .ctx = &rec, .onEvent = Rec.on };
    for (&[_][]const u8{
        \\{"type":"response.reasoning_summary_text.delta","delta":"hmm"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"enc"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_2","summary":[]}}
        ,
        \\{"type":"response.output_text.delta","delta":"hi"}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"c","name":"read"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{}"}
        ,
        \\{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","call_id":"c","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":4,"input_tokens_details":{"cached_tokens":3}}}}
    }) |line| try handle(scratch.allocator(), std.testing.allocator, &st, line, sink);
    // `done` repeats the identity; its arguments were already streamed.
    // Reasoning without encrypted content has nothing to replay.
    try std.testing.expectEqualStrings("think;sig;text;call;args;call;usage;", rec.out.items);
    try std.testing.expectEqual(proto.message.StopReason.tool_use, st.finish.?);
}

test "done completes partially streamed arguments and late identity" {
    const Rec = struct {
        out: std.ArrayList(u8) = .empty,
        fn on(ctx: *anyopaque, e: plugin.provider.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const a = std.testing.allocator;
            switch (e) {
                .tool_call_start => |t| try self.out.print(a, "call{d}:{s}:{s};", .{ t.index, t.id, t.name }),
                .tool_call_delta => |t| try self.out.print(a, "args{d}:{s};", .{ t.index, t.arguments }),
                else => {},
            }
        }
    };
    var rec: Rec = .{};
    defer rec.out.deinit(std.testing.allocator);
    var st: State = .{};
    defer st.deinit(std.testing.allocator);
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const sink: Sink = .{ .ctx = &rec, .onEvent = Rec.on };
    for (&[_][]const u8{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"a\""}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"c","name":"read","arguments":"{\"a\":1}"}}
    }) |line| try handle(scratch.allocator(), std.testing.allocator, &st, line, sink);
    try std.testing.expectEqualStrings("call0::;args0:{\"a\";call0:c:read;args0::1};", rec.out.items);
    try std.testing.expectError(error.InvalidChunk, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"response.function_call_arguments.delta","output_index":-1,"delta":"x"}
    , sink));
}

test "failed response emits failure and incomplete response is length" {
    const Rec = struct {
        failure: ?[]const u8 = null,
        overflow: bool = false,
        fn on(ctx: *anyopaque, event: plugin.provider.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .failure) {
                self.failure = event.failure.message;
                self.overflow = event.failure.overflow;
            }
        }
    };
    var rec: Rec = .{};
    var st: State = .{};
    defer st.deinit(std.testing.allocator);
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const sink: Sink = .{ .ctx = &rec, .onEvent = Rec.on };
    try handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}
    , sink);
    try std.testing.expectEqual(proto.message.StopReason.length, st.finish.?);
    try std.testing.expectError(error.ProviderError, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"response.failed","response":{"error":{"message":"not authorized"}}}
    , sink));
    try std.testing.expectEqualStrings("not authorized", rec.failure.?);
    try std.testing.expect(!rec.overflow);
    try std.testing.expectError(error.ProviderError, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"response.failed","response":{"error":{"code":"context_length_exceeded","message":"Request too big"}}}
    , sink));
    try std.testing.expect(rec.overflow);
    try std.testing.expectError(error.ProviderError, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"response.failed","response":{"error":{"type":"rate_limit_error","code":"context_length_exceeded","message":"Rate limit: too many tokens"}}}
    , sink));
    try std.testing.expect(!rec.overflow);
    try std.testing.expectError(error.IncompleteResponse, handle(scratch.allocator(), std.testing.allocator, &st,
        \\{"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}
    , sink));
    try std.testing.expectEqualStrings("content_filter", rec.failure.?);
}
