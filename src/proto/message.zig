//! Provider-neutral conversation messages.
//! Everything the model sees is one of these, and every one is logged.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
pub const Image = @import("attachment.zig").Image;

pub const FileChange = struct {
    path: []const u8,
    before: []const u8,
    after: []const u8,
    truncated: bool = false,
};

pub const Role = enum { user, assistant, tool_result };

pub const StopReason = enum { stop, length, tool_use, @"error", aborted };

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const Thinking = struct {
    text: []const u8,
    /// Opaque provider data that lets the same provider and model continue
    /// this reasoning in a later request (for example encrypted reasoning).
    signature: ?[]const u8 = null,
};

pub const Content = union(enum) {
    text: []const u8,
    thinking: Thinking,
    tool_call: ToolCall,
    image: Image,

    pub fn jsonStringify(c: Content, s: *Stringify) Stringify.Error!void {
        try s.beginObject();
        switch (c) {
            .text => |t| {
                try field(s, "type", "text");
                try field(s, "text", t);
            },
            .thinking => |t| {
                try field(s, "type", "thinking");
                try field(s, "thinking", t.text);
                if (t.signature) |sig| try field(s, "thinkingSignature", sig);
            },
            .tool_call => |t| {
                try field(s, "type", "toolCall");
                try field(s, "id", t.id);
                try field(s, "name", t.name);
                try s.objectField("arguments");
                const raw = if (t.arguments.len == 0) "{}" else t.arguments;
                if (std.json.validate(std.heap.page_allocator, raw) catch false) {
                    try s.beginWriteRaw();
                    try s.writer.writeAll(raw);
                    s.endWriteRaw();
                } else {
                    // An incomplete model stream may end mid-JSON. Encode the
                    // exact bytes as a string rather than corrupting the log.
                    try s.write(t.arguments);
                    try field(s, "argumentsMalformed", true);
                }
            },
            .image => |image| {
                try field(s, "type", "image");
                try field(s, "mimeType", image.mimeType);
                try field(s, "data", image.data);
            },
        }
        try s.endObject();
    }
};

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cacheRead: u64 = 0,
    cacheWrite: u64 = 0,
    /// USD, when the model's price is known.
    cost: ?f64 = null,

    pub fn jsonStringify(u: Usage, s: *Stringify) Stringify.Error!void {
        try s.beginObject();
        try field(s, "input", u.input);
        try field(s, "output", u.output);
        try field(s, "cacheRead", u.cacheRead);
        try field(s, "cacheWrite", u.cacheWrite);
        if (u.cost) |cost| try field(s, "cost", cost);
        try s.endObject();
    }

    /// These tokens at `price`.
    pub fn priced(u: Usage, price: ?Price) Usage {
        const p = price orelse return u;
        var out = u;
        const f = struct {
            fn of(tokens: u64, per_million: f64) f64 {
                return @as(f64, @floatFromInt(tokens)) * per_million / 1_000_000;
            }
        }.of;
        out.cost = f(u.input, p.input) + f(u.output, p.output) + f(u.cacheRead, p.cacheRead) + f(u.cacheWrite, p.cacheWrite);
        return out;
    }
};

/// USD per million tokens.
pub const Price = struct {
    input: f64 = 0,
    output: f64 = 0,
    cacheRead: f64 = 0,
    cacheWrite: f64 = 0,
};

test "usage priced per million tokens" {
    const u = (Usage{ .input = 1_000_000, .output = 500_000, .cacheRead = 2_000_000 }).priced(.{ .input = 2, .output = 10, .cacheRead = 0.5 });
    try std.testing.expectApproxEqAbs(@as(f64, 8), u.cost.?, 1e-9);
    try std.testing.expect((Usage{}).priced(null).cost == null);
}

pub const Message = struct {
    id: []const u8,
    role: Role,
    content: []const Content,
    timestamp: i64,
    /// Assistant only: completion time in milliseconds on the timestamp clock.
    completedAt: ?i64 = null,

    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    usage: ?Usage = null,
    stopReason: ?StopReason = null,
    errorMessage: ?[]const u8 = null,
    /// Assistant only: hash of the logged `system` entry (prompt and tool
    /// declarations) the request carried.
    systemHash: ?[]const u8 = null,
    /// User only: who wrote it when not the user, e.g. "hook" for text a
    /// hook added to the conversation, "compaction" for a summary.
    origin: ?[]const u8 = null,
    /// Compaction summaries only: the first message the model still sees
    /// verbatim after it, and the estimated context size it replaced.
    firstKeptId: ?[]const u8 = null,
    tokensBefore: ?u64 = null,

    toolCallId: ?[]const u8 = null,
    toolName: ?[]const u8 = null,
    isError: bool = false,
    changes: []const FileChange = &.{},

    pub fn text(m: Message, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (m.content) |c| if (c == .text) try out.appendSlice(gpa, c.text);
        return out.toOwnedSlice(gpa);
    }

    pub fn jsonStringify(m: Message, s: *Stringify) Stringify.Error!void {
        try s.beginObject();
        try field(s, "id", m.id);
        try field(s, "role", @tagName(m.role));
        try s.objectField("content");
        try s.write(m.content);
        try field(s, "timestamp", m.timestamp);
        inline for (.{ "completedAt", "provider", "model", "usage", "stopReason", "errorMessage", "systemHash", "origin", "firstKeptId", "tokensBefore", "toolCallId", "toolName" }) |name| {
            if (@field(m, name)) |v| try field(s, name, v);
        }
        if (m.isError) try field(s, "isError", true);
        if (m.changes.len > 0) try field(s, "changes", m.changes);
        try s.endObject();
    }

    /// Parses a message; strings are allocated in `arena`.
    pub fn parse(arena: Allocator, v: std.json.Value) !Message {
        const o = switch (v) {
            .object => |o| o,
            else => return error.InvalidMessage,
        };
        const role = std.meta.stringToEnum(Role, try str(o, "role")) orelse return error.InvalidMessage;
        const items = switch (o.get("content") orelse return error.InvalidMessage) {
            .array => |a| a.items,
            else => return error.InvalidMessage,
        };
        const content = try arena.alloc(Content, items.len);
        for (items, content) |item, *c| c.* = try parseContent(arena, item);

        var m: Message = .{
            .id = try str(o, "id"),
            .role = role,
            .content = content,
            .timestamp = switch (o.get("timestamp") orelse return error.InvalidMessage) {
                .integer => |i| i,
                else => return error.InvalidMessage,
            },
            .completedAt = if (o.get("completedAt")) |t| switch (t) {
                .integer => |i| i,
                else => null,
            } else null,
            .provider = optStr(o, "provider"),
            .model = optStr(o, "model"),
            .errorMessage = optStr(o, "errorMessage"),
            .systemHash = optStr(o, "systemHash"),
            .origin = optStr(o, "origin"),
            .firstKeptId = optStr(o, "firstKeptId"),
            .tokensBefore = if (o.get("tokensBefore")) |t| switch (t) {
                .integer => |i| if (i >= 0) @intCast(i) else null,
                else => null,
            } else null,
            .toolCallId = optStr(o, "toolCallId"),
            .toolName = optStr(o, "toolName"),
            .isError = if (o.get("isError")) |b| b == .bool and b.bool else false,
        };
        if (optStr(o, "stopReason")) |r| m.stopReason = std.meta.stringToEnum(StopReason, r);
        if (o.get("usage")) |u| m.usage = try std.json.parseFromValueLeaky(Usage, arena, u, .{ .ignore_unknown_fields = true });
        if (o.get("changes")) |v_changes| {
            m.changes = try std.json.parseFromValueLeaky([]const FileChange, arena, v_changes, .{ .ignore_unknown_fields = true });
        }
        return m;
    }
};

fn parseContent(arena: Allocator, v: std.json.Value) !Content {
    const o = switch (v) {
        .object => |o| o,
        else => return error.InvalidMessage,
    };
    const ty = try str(o, "type");
    if (std.mem.eql(u8, ty, "text")) return .{ .text = try str(o, "text") };
    if (std.mem.eql(u8, ty, "thinking")) return .{ .thinking = .{ .text = try str(o, "thinking"), .signature = optStr(o, "thinkingSignature") } };
    if (std.mem.eql(u8, ty, "image")) return .{ .image = try Image.init(arena, try str(o, "mimeType"), try str(o, "data")) };
    if (std.mem.eql(u8, ty, "toolCall")) return .{ .tool_call = .{
        .id = try str(o, "id"),
        .name = try str(o, "name"),
        .arguments = if (o.get("arguments")) |a|
            if (o.get("argumentsMalformed")) |bad|
                if (bad == .bool and bad.bool and a == .string) a.string else try Stringify.valueAlloc(arena, a, .{})
            else
                try Stringify.valueAlloc(arena, a, .{})
        else
            "{}",
    } };
    return error.InvalidMessage;
}

fn field(s: *Stringify, name: []const u8, value: anytype) Stringify.Error!void {
    try s.objectField(name);
    try s.write(value);
}

fn str(o: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return optStr(o, name) orelse error.InvalidMessage;
}

fn optStr(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (o.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

test "assistant message round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m: Message = .{
        .id = "msg_1",
        .role = .assistant,
        .content = &.{
            .{ .thinking = .{ .text = "hmm", .signature = "sig" } },
            .{ .text = "hi" },
            .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a\"}" } },
        },
        .timestamp = 7,
        .completedAt = 12,
        .model = "m",
        .usage = .{ .input = 3, .output = 4 },
        .stopReason = .tool_use,
    };
    const json = try Stringify.valueAlloc(arena, m, .{});
    try std.testing.expectEqualStrings(
        \\{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"hmm","thinkingSignature":"sig"},{"type":"text","text":"hi"},{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"a"}}],"timestamp":7,"completedAt":12,"model":"m","usage":{"input":3,"output":4,"cacheRead":0,"cacheWrite":0},"stopReason":"tool_use"}
    , json);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const back = try Message.parse(arena, v);
    try std.testing.expectEqual(Role.assistant, back.role);
    try std.testing.expectEqual(@as(?i64, 12), back.completedAt);
    try std.testing.expectEqual(StopReason.tool_use, back.stopReason.?);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", back.content[2].tool_call.arguments);
    try std.testing.expectEqualStrings("sig", back.content[0].thinking.signature.?);
    try std.testing.expectEqual(@as(u64, 4), back.usage.?.output);
    const t = try back.text(std.testing.allocator);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("hi", t);
}

test "messages without completedAt retain the old wire format" {
    const a = std.testing.allocator;
    const json =
        \\{"id":"msg_old","role":"assistant","content":[],"timestamp":7}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const message = try Message.parse(a, parsed.value);
    defer a.free(message.content);
    try std.testing.expect(message.completedAt == null);
    const serialized = try Stringify.valueAlloc(a, message, .{});
    defer a.free(serialized);
    try std.testing.expectEqualStrings(json, serialized);
}

test "malformed tool arguments stay exact bytes in a valid JSON log entry" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const partial = "{\"command\":\"unterminated";
    const message: Message = .{
        .id = "m",
        .role = .assistant,
        .content = &.{
            .{ .tool_call = .{ .id = "bad", .name = "bash", .arguments = partial } },
            .{ .tool_call = .{ .id = "string", .name = "bash", .arguments = "\"valid string\"" } },
        },
        .timestamp = 1,
    };
    const json = try Stringify.valueAlloc(arena, message, .{});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const encoded = v.object.get("content").?.array.items;
    try std.testing.expectEqualStrings(partial, encoded[0].object.get("arguments").?.string);
    try std.testing.expect(encoded[0].object.get("argumentsMalformed").?.bool);
    try std.testing.expect(encoded[1].object.get("argumentsMalformed") == null);
    const back = try Message.parse(arena, v);
    try std.testing.expectEqualStrings(partial, back.content[0].tool_call.arguments);
    try std.testing.expectEqualStrings("\"valid string\"", back.content[1].tool_call.arguments);
}

test "image and structured change survive message persistence" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const m: Message = .{ .id = "m", .role = .user, .timestamp = 0, .content = &.{
        .{ .text = "look" }, .{ .image = try Image.init(a, "image/jpeg", "YWJj") },
    }, .changes = &.{.{ .path = "a", .before = "x", .after = "y" }} };
    const json = try Stringify.valueAlloc(a, m, .{});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const restored = try Message.parse(a, v);
    try std.testing.expectEqualStrings("YWJj", restored.content[1].image.data);
    try std.testing.expectEqualStrings("y", restored.changes[0].after);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":"m","role":"user","content":[{"type":"image","mimeType":"image/png","data":"!!!"}],"timestamp":0}
    , .{});
    try std.testing.expectError(error.InvalidImageData, Message.parse(a, bad));
}
