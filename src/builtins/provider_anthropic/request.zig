//! Anthropic Messages request body. History is regrouped into alternating
//! user and assistant turns: tool results join the user turn that follows
//! the calls. Signed thinking replays before the text and calls it led to,
//! but only from the current run and the current system prompt and tools:
//! a thinking block is bound to everything sent before it, which a new
//! prompt, a hook or a compaction may have changed, and the API rejects a
//! block whose prefix changed. Dropping the older ones is allowed. The system prompt and the
//! newest block carry a cache breakpoint.
const std = @import("std");
const plugin = @import("plugin");
const proto = @import("proto");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

pub const default_max_tokens = 8192;

const Block = union(enum) {
    text: []const u8,
    image: proto.message.Image,
    tool_use: proto.message.ToolCall,
    tool_result: proto.Message,
    thinking: proto.message.Thinking,
    /// A block kept verbatim (redacted thinking).
    raw: []const u8,
};

const Turn = struct { role: []const u8, blocks: std.ArrayList(Block) = .empty };

/// Thinking budgets (tokens) for models that take `budget_tokens`.
const budgets = std.EnumArray(proto.thinking.Level, u64).init(.{
    .off = 0,
    .minimal = 1024,
    .low = 2048,
    .medium = 8192,
    .high = 16384,
    .xhigh = 32768,
});

/// Newer models choose how much to think from an effort (`adaptive`);
/// older ones take a token budget, which must leave room for the answer
/// within `max_tokens`, or can have thinking disabled.
fn writeThinking(s: *Stringify, model: []const u8, level: proto.thinking.Level, max_tokens: u64) !void {
    // Some adaptive models always think: there `off` is the lowest effort.
    if (!budgeted(model)) {
        try field(s, "thinking", .{ .type = "adaptive", .display = "summarized" });
        const effort: []const u8 = switch (level) {
            .off, .minimal, .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "max",
        };
        return field(s, "output_config", .{ .effort = effort });
    }
    if (level == .off) return field(s, "thinking", .{ .type = "disabled" });
    const budget = @min(budgets.get(level), max_tokens -| 1024);
    if (budget < 1024) return;
    try field(s, "thinking", .{ .type = "enabled", .budget_tokens = budget, .display = "summarized" });
}

/// Models from before adaptive thinking.
fn budgeted(model: []const u8) bool {
    const older = [_][]const u8{
        "claude-3",          "claude-opus-4-0",   "claude-opus-4-1",      "claude-opus-4-5",  "claude-opus-4-2025",
        "claude-sonnet-4-0", "claude-sonnet-4-5", "claude-sonnet-4-2025", "claude-haiku-4-5",
    };
    for (older) |prefix| if (std.mem.startsWith(u8, model, prefix)) return true;
    return false;
}

/// `max_tokens` 0 uses `default_max_tokens`. `arena` holds the regrouped
/// turns while encoding.
pub fn encode(arena: Allocator, w: *std.Io.Writer, req: plugin.provider.Request, max_tokens: u64) !void {
    const turns = try group(arena, req.messages, req.system_hash);
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "model", req.model);
    const limit = if (max_tokens > 0) max_tokens else default_max_tokens;
    try field(&s, "max_tokens", limit);
    try field(&s, "stream", true);
    if (req.thinking) |level| try writeThinking(&s, req.model, level, limit);
    if (req.system.len > 0) {
        try s.objectField("system");
        try s.write(.{.{ .type = "text", .text = req.system, .cache_control = .{ .type = "ephemeral" } }});
    }
    try s.objectField("messages");
    try s.beginArray();
    for (turns, 0..) |turn, t| {
        try s.beginObject();
        try field(&s, "role", turn.role);
        try s.objectField("content");
        try s.beginArray();
        for (turn.blocks.items, 0..) |block, b| {
            const last = t == turns.len - 1 and b == turn.blocks.items.len - 1;
            try writeBlock(&s, block, last);
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    if (req.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (req.tools) |tool| {
            try s.beginObject();
            try field(&s, "name", tool.name);
            try field(&s, "description", tool.description);
            try s.objectField("input_schema");
            try raw(&s, tool.parameters);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

/// Turns with at least one block; consecutive messages of one role merge.
fn group(arena: Allocator, messages: []const proto.Message, system_hash: ?[]const u8) ![]const Turn {
    // The current run starts after the last user message; a summary is
    // logged after the messages it keeps, which then have a new prefix.
    var run_start: usize = 0;
    var summarized_at: i64 = std.math.minInt(i64);
    for (messages, 0..) |m, i| if (m.role == .user) {
        run_start = i + 1;
        if (m.origin) |o| if (std.mem.eql(u8, o, "compaction")) {
            summarized_at = @max(summarized_at, m.timestamp);
        };
    };
    var turns: std.ArrayList(Turn) = .empty;
    for (messages, 0..) |m, index| {
        const same_prompt = if (system_hash) |want| if (m.systemHash) |got| std.mem.eql(u8, want, got) else false else true;
        const replay = index >= run_start and m.timestamp >= summarized_at and same_prompt;
        const role = if (m.role == .assistant) "assistant" else "user";
        var blocks: std.ArrayList(Block) = .empty;
        switch (m.role) {
            .tool_result => try blocks.append(arena, .{ .tool_result = m }),
            .user => for (m.content) |c| switch (c) {
                .text => |text| if (text.len > 0) try blocks.append(arena, .{ .text = text }),
                .image => |image| try blocks.append(arena, .{ .image = image }),
                else => {},
            },
            .assistant => for (m.content) |c| switch (c) {
                .text => |text| if (std.mem.trim(u8, text, " \t\r\n").len > 0) try blocks.append(arena, .{ .text = text }),
                .thinking => |t| if (t.signature) |sig| if (replay and sig.len > 0) {
                    try blocks.append(arena, if (isRedacted(sig)) .{ .raw = sig } else .{ .thinking = t });
                },
                .tool_call => |call| try blocks.append(arena, .{ .tool_use = call }),
                .image => {},
            },
        }
        if (blocks.items.len == 0) continue;
        if (turns.items.len > 0 and std.mem.eql(u8, turns.items[turns.items.len - 1].role, role)) {
            const into = &turns.items[turns.items.len - 1].blocks;
            // Results answer the calls just before them, so they lead.
            if (m.role == .tool_result) {
                var at: usize = 0;
                while (at < into.items.len and into.items[at] == .tool_result) at += 1;
                try into.insertSlice(arena, at, blocks.items);
            } else try into.appendSlice(arena, blocks.items);
        } else try turns.append(arena, .{ .role = role, .blocks = blocks });
    }
    return turns.items;
}

fn writeBlock(s: *Stringify, block: Block, cache: bool) !void {
    if (block == .raw) return raw(s, block.raw);
    try s.beginObject();
    switch (block) {
        .text => |text| {
            try field(s, "type", "text");
            try field(s, "text", text);
        },
        .image => |image| {
            try field(s, "type", "image");
            try field(s, "source", .{ .type = "base64", .media_type = image.mimeType, .data = image.data });
        },
        .tool_use => |call| {
            try field(s, "type", "tool_use");
            try field(s, "id", call.id);
            try field(s, "name", call.name);
            try s.objectField("input");
            try raw(s, if (isObject(call.arguments)) call.arguments else "{}");
        },
        .tool_result => |m| {
            try field(s, "type", "tool_result");
            try field(s, "tool_use_id", m.toolCallId orelse "");
            if (m.isError) try field(s, "is_error", true);
            try s.objectField("content");
            try s.beginArray();
            var any = false;
            for (m.content) |c| switch (c) {
                .text => |text| if (text.len > 0) {
                    try s.write(.{ .type = "text", .text = text });
                    any = true;
                },
                .image => |image| {
                    try s.write(.{ .type = "image", .source = .{ .type = "base64", .media_type = image.mimeType, .data = image.data } });
                    any = true;
                },
                else => {},
            };
            if (!any) try s.write(.{ .type = "text", .text = "(no output)" });
            try s.endArray();
        },
        .thinking => |t| {
            try field(s, "type", "thinking");
            try field(s, "thinking", t.text);
            try field(s, "signature", t.signature.?);
        },
        .raw => unreachable,
    }
    if (cache) try field(s, "cache_control", .{ .type = "ephemeral" });
    try s.endObject();
}

/// Redacted thinking is logged as its whole block; a signature is base64.
fn isRedacted(sig: []const u8) bool {
    return std.mem.startsWith(u8, sig, "{\"type\":\"redacted_thinking\"") and isObject(sig);
}

/// Logged data is replayed raw only when it is a well-formed object, so a
/// damaged log cannot corrupt the request body.
fn isObject(text: []const u8) bool {
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t\r\n"), "{")) return false;
    return std.json.validate(std.heap.page_allocator, text) catch false;
}

fn raw(s: *Stringify, json: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(json);
    s.endWriteRaw();
}

fn field(s: *Stringify, key: []const u8, value: anytype) Stringify.Error!void {
    try s.objectField(key);
    try s.write(value);
}

fn expectBody(req: plugin.provider.Request, max_tokens: u64, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try encode(arena.allocator(), &out.writer, req, max_tokens);
    try std.testing.expectEqualStrings(want, out.written());
}

test "tool calls, results and signed thinking regroup into alternating turns" {
    try expectBody(.{ .model = "claude", .system = "help", .messages = &.{
        .{ .id = "u", .role = .user, .timestamp = 0, .content = &.{.{ .text = "hi" }} },
        .{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{
            .{ .thinking = .{ .text = "plan", .signature = "c2ln" } },
            .{ .thinking = .{ .text = "unsigned" } },
            .{ .text = "  " },
            .{ .tool_call = .{ .id = "t1", .name = "read", .arguments = "{\"path\":\"a\"}" } },
            .{ .tool_call = .{ .id = "t2", .name = "read", .arguments = "oops" } },
        } },
        .{ .id = "r1", .role = .tool_result, .timestamp = 0, .toolCallId = "t1", .content = &.{.{ .text = "one" }} },
        .{ .id = "r2", .role = .tool_result, .timestamp = 0, .toolCallId = "t2", .isError = true, .content = &.{} },
    }, .tools = &.{.{ .name = "read", .description = "Read", .parameters = "{\"type\":\"object\"}" }} }, 0,
        \\{"model":"claude","max_tokens":8192,"stream":true,"system":[{"type":"text","text":"help","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"plan","signature":"c2ln"},{"type":"tool_use","id":"t1","name":"read","input":{"path":"a"}},{"type":"tool_use","id":"t2","name":"read","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"one"}]},{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"(no output)"}],"cache_control":{"type":"ephemeral"}}]}],"tools":[{"name":"read","description":"Read","input_schema":{"type":"object"}}]}
    );
}

test "a prompt queued after tool results joins their turn and ends the run's thinking" {
    const redacted =
        \\{"type":"redacted_thinking","data":"xyz"}
    ;
    try expectBody(.{ .model = "m", .system = "", .messages = &.{
        .{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{
            .{ .thinking = .{ .text = "", .signature = redacted } },
            .{ .tool_call = .{ .id = "t", .name = "x", .arguments = "{}" } },
        } },
        .{ .id = "r", .role = .tool_result, .timestamp = 0, .toolCallId = "t", .content = &.{.{ .text = "ok" }} },
        .{ .id = "u", .role = .user, .timestamp = 0, .content = &.{ .{ .text = "more" }, .{ .image = .{ .mimeType = "image/png", .data = "AA==" } } } },
        .{ .id = "e", .role = .assistant, .timestamp = 0, .content = &.{} },
    } }, 1000,
        \\{"model":"m","max_tokens":1000,"stream":true,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"x","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":"ok"}]},{"type":"text","text":"more"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="},"cache_control":{"type":"ephemeral"}}]}]}
    );
}

test "thinking replays only from the current run and after a summary" {
    const signed: proto.message.Content = .{ .thinking = .{ .text = "t", .signature = "c2ln" } };
    const answer: proto.message.Content = .{ .text = "a" };
    // An earlier run's thinking is dropped.
    try expectBody(.{ .model = "m", .system = "", .messages = &.{
        .{ .id = "u1", .role = .user, .timestamp = 1, .content = &.{.{ .text = "one" }} },
        .{ .id = "a1", .role = .assistant, .timestamp = 2, .content = &.{ signed, answer } },
        .{ .id = "u2", .role = .user, .timestamp = 3, .content = &.{.{ .text = "two" }} },
        .{ .id = "a2", .role = .assistant, .timestamp = 4, .content = &.{ signed, answer } },
    } }, 10,
        \\{"model":"m","max_tokens":10,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"one"}]},{"role":"assistant","content":[{"type":"text","text":"a"}]},{"role":"user","content":[{"type":"text","text":"two"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"t","signature":"c2ln"},{"type":"text","text":"a","cache_control":{"type":"ephemeral"}}]}]}
    );
    // A reply made under another system prompt or tool set is dropped.
    try expectBody(.{ .model = "m", .system = "", .system_hash = "new", .messages = &.{
        .{ .id = "u", .role = .user, .timestamp = 1, .content = &.{.{ .text = "go" }} },
        .{ .id = "a1", .role = .assistant, .timestamp = 2, .systemHash = "old", .content = &.{ signed, answer } },
        .{ .id = "a2", .role = .assistant, .timestamp = 3, .systemHash = "new", .content = &.{ signed, answer } },
    } }, 10,
        \\{"model":"m","max_tokens":10,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]},{"role":"assistant","content":[{"type":"text","text":"a"},{"type":"thinking","thinking":"t","signature":"c2ln"},{"type":"text","text":"a","cache_control":{"type":"ephemeral"}}]}]}
    );
    // Redacted thinking replays as it came.
    try expectBody(.{ .model = "m", .system = "", .messages = &.{
        .{ .id = "u", .role = .user, .timestamp = 1, .content = &.{.{ .text = "go" }} },
        .{ .id = "a", .role = .assistant, .timestamp = 2, .content = &.{ .{ .thinking = .{ .text = "", .signature = "{\"type\":\"redacted_thinking\",\"data\":\"xyz\"}" } }, answer } },
    } }, 10,
        \\{"model":"m","max_tokens":10,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]},{"role":"assistant","content":[{"type":"redacted_thinking","data":"xyz"},{"type":"text","text":"a","cache_control":{"type":"ephemeral"}}]}]}
    );
    // A kept message older than the summary lost its prefix; a newer one did not.
    try expectBody(.{ .model = "m", .system = "", .messages = &.{
        .{ .id = "s", .role = .user, .timestamp = 5, .origin = "compaction", .content = &.{.{ .text = "summary" }} },
        .{ .id = "a1", .role = .assistant, .timestamp = 2, .content = &.{ signed, answer } },
        .{ .id = "a2", .role = .assistant, .timestamp = 6, .content = &.{ signed, answer } },
    } }, 10,
        \\{"model":"m","max_tokens":10,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"summary"}]},{"role":"assistant","content":[{"type":"text","text":"a"},{"type":"thinking","thinking":"t","signature":"c2ln"},{"type":"text","text":"a","cache_control":{"type":"ephemeral"}}]}]}
    );
}

test "thinking levels become an adaptive effort, or a budget on older models" {
    const hi: []const proto.Message = &.{.{ .id = "u", .role = .user, .timestamp = 0, .content = &.{.{ .text = "hi" }} }};
    try expectBody(.{ .model = "claude-sonnet-5", .thinking = .xhigh, .system = "", .messages = hi }, 64000,
        \\{"model":"claude-sonnet-5","max_tokens":64000,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"max"},"messages":[{"role":"user","content":[{"type":"text","text":"hi","cache_control":{"type":"ephemeral"}}]}]}
    );
    // The budget leaves room for the answer within max_tokens.
    try expectBody(.{ .model = "claude-sonnet-4-5", .thinking = .high, .system = "", .messages = hi }, 0,
        \\{"model":"claude-sonnet-4-5","max_tokens":8192,"stream":true,"thinking":{"type":"enabled","budget_tokens":7168,"display":"summarized"},"messages":[{"role":"user","content":[{"type":"text","text":"hi","cache_control":{"type":"ephemeral"}}]}]}
    );
    try expectBody(.{ .model = "claude-opus-5-5", .thinking = .off, .system = "", .messages = hi }, 1000,
        \\{"model":"claude-opus-5-5","max_tokens":1000,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"low"},"messages":[{"role":"user","content":[{"type":"text","text":"hi","cache_control":{"type":"ephemeral"}}]}]}
    );
    try expectBody(.{ .model = "claude-sonnet-4-5", .thinking = .off, .system = "", .messages = hi }, 1000,
        \\{"model":"claude-sonnet-4-5","max_tokens":1000,"stream":true,"thinking":{"type":"disabled"},"messages":[{"role":"user","content":[{"type":"text","text":"hi","cache_control":{"type":"ephemeral"}}]}]}
    );
}
