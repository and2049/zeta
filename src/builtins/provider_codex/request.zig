//! Stateless Responses input: replay visible history, function calls/results
//! and signed reasoning items, in the order the model produced them. Reasoning
//! without a signature (plain summaries) is not replayable.
const std = @import("std");
const plugin = @import("plugin");
const proto = @import("proto");
const Stringify = std.json.Stringify;

pub fn encode(w: *std.Io.Writer, req: plugin.provider.Request) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "model", req.model);
    try field(&s, "stream", true);
    try field(&s, "store", false);
    if (req.session_id) |id| try field(&s, "prompt_cache_key", id);
    if (req.thinking) |level| try field(&s, "reasoning", .{ .effort = @import("../provider_openai/request.zig").effort(level), .summary = "auto" });
    // Without server-side storage, encrypted reasoning is the only way the
    // model keeps its reasoning across tool calls.
    try field(&s, "include", [_][]const u8{"reasoning.encrypted_content"});
    try field(&s, "instructions", req.system);
    try s.objectField("input");
    try s.beginArray();
    for (req.messages) |m| switch (m.role) {
        .user => {
            try s.beginObject();
            try field(&s, "role", "user");
            try s.objectField("content");
            try s.beginArray();
            for (m.content) |c| switch (c) {
                .text => |text| try s.write(.{ .type = "input_text", .text = text }),
                .image => |image| try inputImage(&s, image),
                else => {},
            };
            try s.endArray();
            try s.endObject();
        },
        .tool_result => {
            try s.beginObject();
            try field(&s, "type", "function_call_output");
            try field(&s, "call_id", m.toolCallId orelse "");
            try s.objectField("output");
            const images = for (m.content) |c| {
                if (c == .image) break true;
            } else false;
            if (images) {
                // With images the output is a list of input parts.
                try s.beginArray();
                for (m.content) |c| switch (c) {
                    .text => |text| try s.write(.{ .type = "input_text", .text = text }),
                    .image => |image| try inputImage(&s, image),
                    else => {},
                };
                try s.endArray();
            } else {
                try s.beginWriteRaw();
                try s.writer.writeByte('"');
                for (m.content) |c| if (c == .text) try Stringify.encodeJsonStringChars(c.text, .{}, s.writer);
                try s.writer.writeByte('"');
                s.endWriteRaw();
            }
            try s.endObject();
        },
        .assistant => {
            var i: usize = 0;
            while (i < m.content.len) {
                switch (m.content[i]) {
                    .text => {
                        // Consecutive text blocks form one message item.
                        try s.beginObject();
                        try field(&s, "role", "assistant");
                        try s.objectField("content");
                        try s.beginArray();
                        while (i < m.content.len and m.content[i] == .text) : (i += 1) {
                            try s.write(.{ .type = "output_text", .text = m.content[i].text });
                        }
                        try s.endArray();
                        try s.endObject();
                        continue;
                    },
                    .thinking => |t| if (t.signature) |sig| if (isReasoningItem(sig)) {
                        try s.beginWriteRaw();
                        try s.writer.writeAll(sig);
                        s.endWriteRaw();
                    },
                    .tool_call => |c| try s.write(.{
                        .type = "function_call",
                        .call_id = c.id,
                        .name = c.name,
                        .arguments = c.arguments,
                    }),
                    .image => {},
                }
                i += 1;
            }
        },
    };
    try s.endArray();
    if (req.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (req.tools) |t| {
            try s.beginObject();
            try field(&s, "type", "function");
            try field(&s, "name", t.name);
            try field(&s, "description", t.description);
            try s.objectField("parameters");
            try s.beginWriteRaw();
            try s.writer.writeAll(t.parameters);
            s.endWriteRaw();
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

/// Signatures come from the session log; replay only a well-formed reasoning
/// item so a damaged log cannot corrupt the request body.
fn inputImage(s: *Stringify, image: proto.attachment.Image) Stringify.Error!void {
    try s.beginObject();
    try field(s, "type", "input_image");
    try s.objectField("image_url");
    try s.beginWriteRaw();
    try s.writer.writeAll("\"data:");
    try Stringify.encodeJsonStringChars(image.mimeType, .{}, s.writer);
    try s.writer.writeAll(";base64,");
    try Stringify.encodeJsonStringChars(image.data, .{}, s.writer);
    try s.writer.writeByte('"');
    s.endWriteRaw();
    try s.endObject();
}

fn isReasoningItem(sig: []const u8) bool {
    if (!std.mem.startsWith(u8, sig, "{")) return false;
    if (!(std.json.validate(std.heap.page_allocator, sig) catch false)) return false;
    // Signatures are written compactly, and an escaped copy inside a string
    // value cannot match this.
    return std.mem.indexOf(u8, sig, "\"type\":\"reasoning\"") != null;
}

fn field(s: *Stringify, key: []const u8, value: anytype) Stringify.Error!void {
    try s.objectField(key);
    try s.write(value);
}

test "replays function calls and outputs as Responses items" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(&out.writer, .{ .model = "gpt-5.5", .session_id = "ses_1", .thinking = .high, .system = "help", .messages = &.{
        .{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{ .{ .thinking = .{ .text = "private" } }, .{ .tool_call = .{ .id = "call", .name = "read", .arguments = "{}" } } } },
        .{ .id = "b", .role = .tool_result, .timestamp = 0, .toolCallId = "call", .content = &.{.{ .text = "ok" }} },
    }, .tools = &.{.{ .name = "read", .description = "Read", .parameters = "{\"type\":\"object\"}" }} });
    try std.testing.expectEqualStrings(
        \\{"model":"gpt-5.5","stream":true,"store":false,"prompt_cache_key":"ses_1","reasoning":{"effort":"high","summary":"auto"},"include":["reasoning.encrypted_content"],"instructions":"help","input":[{"type":"function_call","call_id":"call","name":"read","arguments":"{}"},{"type":"function_call_output","call_id":"call","output":"ok"}],"tools":[{"type":"function","name":"read","description":"Read","parameters":{"type":"object"}}]}
    , out.written());
}

test "signed reasoning replays in order before the calls it led to" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const item =
        \\{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"enc"}
    ;
    try encode(&out.writer, .{ .model = "m", .system = "", .messages = &.{
        .{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{
            .{ .thinking = .{ .text = "", .signature = item } },
            .{ .text = "a" },
            .{ .text = "b" },
            .{ .thinking = .{ .text = "", .signature = "{\"type\":\"reasoning\"" } },
            .{ .tool_call = .{ .id = "call", .name = "read", .arguments = "{}" } },
            .{ .text = "c" },
        } },
    } });
    try std.testing.expectEqualStrings(
        \\{"model":"m","stream":true,"store":false,"include":["reasoning.encrypted_content"],"instructions":"","input":[{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"enc"},{"role":"assistant","content":[{"type":"output_text","text":"a"},{"type":"output_text","text":"b"}]},{"type":"function_call","call_id":"call","name":"read","arguments":"{}"},{"role":"assistant","content":[{"type":"output_text","text":"c"}]}]}
    , out.written());
}

test "a tool result with an image is a list of input parts" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(&out.writer, .{ .model = "m", .system = "", .messages = &.{
        .{ .id = "b", .role = .tool_result, .timestamp = 0, .toolCallId = "call", .content = &.{ .{ .text = "Read image" }, .{ .image = .{ .mimeType = "image/png", .data = "AA==" } } } },
    } });
    try std.testing.expect(std.mem.indexOf(u8, out.written(),
        \\"output":[{"type":"input_text","text":"Read image"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}]
    ) != null);
}
