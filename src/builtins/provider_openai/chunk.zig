//! Parses one chat-completions stream chunk (`data: {…}`) into provider
//! events. Tolerates the common dialects: `reasoning_content` (DeepSeek) and
//! `reasoning` (OpenRouter) for thinking, usage in a trailing chunk.

const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Sink = plugin.provider.Sink;
const provider_error = @import("../provider_error.zig");

pub const State = struct {
    finish: ?proto.message.StopReason = null,
};

pub fn handle(arena: Allocator, state: *State, data: []const u8, secret: ?[]const u8, sink: Sink) !void {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return error.InvalidChunk;
    const root = obj(v) orelse return error.InvalidChunk;

    if (root.get("error")) |e| {
        const msg = if (obj(e)) |eo| str(eo, "message") else if (e == .string) e.string else null;
        try sink.emit(.{ .failure = try provider_error.stream(arena, msg orelse "stream error without a message", data, secret) });
        return error.ProviderError;
    }

    if (root.get("choices")) |choices| if (choices == .array) for (choices.array.items) |choice| {
        const c = obj(choice) orelse continue;
        if (c.get("delta")) |d| if (obj(d)) |delta| try handleDelta(delta, sink);
        if (str(c, "finish_reason")) |r| state.finish = mapFinish(r) orelse {
            // A filtered or unknown finish is an error, not a stop.
            try sink.emit(.{ .failure = .{
                .message = try std.fmt.allocPrint(arena, "Provider finish_reason: {s}", .{r[0..@min(r.len, 64)]}),
                .retryable = std.mem.eql(u8, r, "network_error"),
            } });
            return error.ProviderFinishReason;
        };
    };

    if (root.get("usage")) |u| if (obj(u)) |usage| {
        const cached = if (usage.get("prompt_tokens_details")) |d| if (obj(d)) |dd| int(dd, "cached_tokens") else 0 else 0;
        const prompt = int(usage, "prompt_tokens");
        try sink.emit(.{ .usage = .{
            .input = prompt -| cached,
            .output = int(usage, "completion_tokens"),
            .cacheRead = cached,
        } });
    };
}

fn handleDelta(delta: std.json.ObjectMap, sink: Sink) !void {
    const thinking = str(delta, "reasoning_content") orelse str(delta, "reasoning");
    if (thinking) |t| try sink.emit(.{ .thinking_delta = t });
    if (str(delta, "content")) |t| try sink.emit(.{ .text_delta = t });

    const calls = delta.get("tool_calls") orelse return;
    if (calls != .array) return;
    for (calls.array.items) |call_v| {
        const call = obj(call_v) orelse continue;
        const index = try callIndex(call);
        const func = if (call.get("function")) |f| obj(f) else null;
        // Any chunk may carry the call's id or name (some services send them
        // after the first arguments); the assembler fills in missing fields.
        const id = str(call, "id") orelse "";
        const name = if (func) |f| str(f, "name") orelse "" else "";
        if (id.len > 0 or name.len > 0) try sink.emit(.{ .tool_call_start = .{ .index = index, .id = id, .name = name } });
        if (func) |f| if (str(f, "arguments")) |args| {
            if (args.len > 0) try sink.emit(.{ .tool_call_delta = .{ .index = index, .arguments = args } });
        };
    }
}

/// A missing index means the only call (index 0).
fn callIndex(call: std.json.ObjectMap) !u32 {
    const v = call.get("index") orelse return 0;
    if (v != .integer) return error.InvalidChunk;
    return std.math.cast(u32, v.integer) orelse error.InvalidChunk;
}

fn mapFinish(r: []const u8) ?proto.message.StopReason {
    if (std.mem.eql(u8, r, "tool_calls") or std.mem.eql(u8, r, "function_call")) return .tool_use;
    if (std.mem.eql(u8, r, "length")) return .length;
    if (std.mem.eql(u8, r, "stop") or std.mem.eql(u8, r, "end")) return .stop;
    return null;
}

fn obj(v: std.json.Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}

fn str(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: std.json.ObjectMap, name: []const u8) u64 {
    const v = o.get(name) orelse return 0;
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
}

const Recorder = struct {
    events: std.ArrayList(u8) = .empty,
    arena: Allocator,

    fn sink(r: *Recorder) Sink {
        return .{ .ctx = r, .onEvent = on };
    }
    fn on(ctx: *anyopaque, e: plugin.provider.Event) anyerror!void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const line = switch (e) {
            .text_delta => |t| try std.fmt.allocPrint(r.arena, "text:{s};", .{t}),
            .thinking_delta => |t| try std.fmt.allocPrint(r.arena, "think:{s};", .{t}),
            .thinking_signature => |t| try std.fmt.allocPrint(r.arena, "sig:{s};", .{t}),
            .tool_call_start => |t| try std.fmt.allocPrint(r.arena, "call{d}:{s}:{s};", .{ t.index, t.id, t.name }),
            .tool_call_delta => |t| try std.fmt.allocPrint(r.arena, "args{d}:{s};", .{ t.index, t.arguments }),
            .usage => |u| try std.fmt.allocPrint(r.arena, "usage:{d}/{d}/{d};", .{ u.input, u.output, u.cacheRead }),
            .done => |d| try std.fmt.allocPrint(r.arena, "done:{t};", .{d}),
            .failure => |f| try std.fmt.allocPrint(r.arena, "fail:{s}{s};", .{ f.message, if (f.retryable) "(retry)" else "" }),
        };
        try r.events.appendSlice(r.arena, line);
    }
};

test "text, reasoning, tool call deltas, finish and usage" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rec: Recorder = .{ .arena = arena };
    var st: State = .{};
    const chunks = [_][]const u8{
        \\{"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"hm"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"Hi"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"read","arguments":""}}]}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":1}"}}]},"finish_reason":"tool_calls"}]}
        ,
        \\{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":4}}}
    };
    for (chunks) |c| try handle(arena, &st, c, null, rec.sink());
    try std.testing.expectEqualStrings("think:hm;text:Hi;call0:c1:read;args0:{\"a\":1};usage:6/3/4;", rec.events.items);
    try std.testing.expectEqual(proto.message.StopReason.tool_use, st.finish.?);
}

test "late tool call identity, high and invalid indexes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rec: Recorder = .{ .arena = arena };
    var st: State = .{};
    const chunks = [_][]const u8{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":63,"function":{"arguments":"{}"}},{"index":64,"id":"c64","function":{"name":"read","arguments":""}}]}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":63,"id":"c63","function":{"name":"bash"}}]}}]}
    };
    for (chunks) |c| try handle(arena, &st, c, null, rec.sink());
    try std.testing.expectEqualStrings("args63:{};call64:c64:read;call63:c63:bash;", rec.events.items);
    try std.testing.expectError(error.InvalidChunk, handle(arena, &st,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":-1,"id":"x"}]}}]}
    , null, rec.sink()));
}

test "error chunk reports failure" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var rec: Recorder = .{ .arena = arena_state.allocator() };
    var st: State = .{};
    try std.testing.expectError(error.ProviderError, handle(arena_state.allocator(), &st, "{\"error\":{\"message\":\"bad\"}}", null, rec.sink()));
    try std.testing.expectError(error.ProviderError, handle(arena_state.allocator(), &st, "{\"error\":{\"message\":\"Server overloaded\\nretry\"}}", null, rec.sink()));
    try std.testing.expectEqualStrings("fail:bad;fail:Server overloaded retry(retry);", rec.events.items);
}

test "stream error redacts the request key" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rec: Recorder = .{ .arena = arena };
    var st: State = .{};
    try std.testing.expectError(error.ProviderError, handle(arena, &st, "{\"error\":{\"message\":\"Invalid key sk-secret-123456\"}}", "sk-secret-123456", rec.sink()));
    try std.testing.expectEqualStrings("fail:Invalid key [redacted];", rec.events.items);
}

test "content_filter and unknown finish reasons are errors; end is a stop" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rec: Recorder = .{ .arena = arena };
    var st: State = .{};
    try handle(arena, &st, "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"end\"}]}", null, rec.sink());
    try std.testing.expectEqual(proto.message.StopReason.stop, st.finish.?);
    try std.testing.expectError(error.ProviderFinishReason, handle(arena, &st, "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}", null, rec.sink()));
    try std.testing.expectError(error.ProviderFinishReason, handle(arena, &st, "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"network_error\"}]}", null, rec.sink()));
    try std.testing.expectEqualStrings("fail:Provider finish_reason: content_filter;fail:Provider finish_reason: network_error(retry);", rec.events.items);
}
