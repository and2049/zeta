const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Stringify = std.json.Stringify;
const Message = proto.Message;

/// `cache_key`, when set, goes out as `prompt_cache_key`.
pub fn encode(w: *std.Io.Writer, req: plugin.provider.Request, cache_key: ?[]const u8) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("model");
    try s.write(req.model);
    if (cache_key) |key| {
        try s.objectField("prompt_cache_key");
        try s.write(key);
    }
    if (req.thinking) |level| {
        try s.objectField("reasoning_effort");
        try s.write(effort(level));
    }
    try s.objectField("stream");
    try s.write(true);
    try s.objectField("stream_options");
    try s.write(.{ .include_usage = true });

    try s.objectField("messages");
    try s.beginArray();
    if (req.system.len > 0) try s.write(.{ .role = "system", .content = req.system });
    for (req.messages, 0..) |m, i| {
        try writeMessage(&s, m);
        // Tool messages hold text only: the images of a group of tool
        // results follow it as a user message.
        const last_of_group = m.role == .tool_result and (i + 1 == req.messages.len or req.messages[i + 1].role != .tool_result);
        if (last_of_group) try toolImages(&s, req.messages[0 .. i + 1]);
    }
    try s.endArray();

    if (req.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (req.tools) |t| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("function");
            try s.beginObject();
            try s.objectField("name");
            try s.write(t.name);
            try s.objectField("description");
            try s.write(t.description);
            try s.objectField("parameters");
            try writeRaw(&s, t.parameters);
            try s.endObject();
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

/// OpenAI's `reasoning_effort` for a level; `off` is `none`.
pub fn effort(level: proto.thinking.Level) []const u8 {
    return if (level == .off) "none" else @tagName(level);
}

fn writeMessage(s: *Stringify, m: Message) Stringify.Error!void {
    switch (m.role) {
        .user => {
            try s.beginObject();
            try s.objectField("role");
            try s.write("user");
            try s.objectField("content");
            if (hasImage(m)) {
                try s.beginArray();
                for (m.content) |c| switch (c) {
                    .text => |text| try s.write(.{ .type = "text", .text = text }),
                    .image => |image| try writeImage(s, image),
                    else => {},
                };
                try s.endArray();
            } else try writeText(s, m);
            try s.endObject();
        },
        .tool_result => {
            try s.beginObject();
            try s.objectField("role");
            try s.write("tool");
            try s.objectField("tool_call_id");
            try s.write(m.toolCallId orelse "");
            try s.objectField("content");
            if (hasText(m)) try writeText(s, m) else try s.write(if (hasImage(m)) "(see attached image)" else "");
            try s.endObject();
        },
        .assistant => {
            // Chat completions carries no reasoning, so a reply with neither
            // text nor tool calls (empty, failed, or reasoning-only) would be
            // `content:null` with nothing else, which the API rejects.
            if (!hasText(m) and !hasToolCall(m)) return;
            try s.beginObject();
            try s.objectField("role");
            try s.write("assistant");
            try s.objectField("content");
            if (hasText(m)) try writeText(s, m) else try s.write(null);
            var first_call = true;
            for (m.content) |c| {
                if (c != .tool_call) continue;
                if (first_call) {
                    try s.objectField("tool_calls");
                    try s.beginArray();
                    first_call = false;
                }
                try s.write(.{
                    .id = c.tool_call.id,
                    .type = "function",
                    .function = .{ .name = c.tool_call.name, .arguments = c.tool_call.arguments },
                });
            }
            if (!first_call) try s.endArray();
            try s.endObject();
        },
    }
}

fn writeImage(s: *Stringify, image: proto.attachment.Image) Stringify.Error!void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("image_url");
    try s.objectField("image_url");
    try s.beginObject();
    try s.objectField("url");
    try s.beginWriteRaw();
    try s.writer.writeByte('"');
    try s.writer.writeAll("data:");
    try Stringify.encodeJsonStringChars(image.mimeType, .{}, s.writer);
    try s.writer.writeAll(";base64,");
    try Stringify.encodeJsonStringChars(image.data, .{}, s.writer);
    try s.writer.writeByte('"');
    s.endWriteRaw();
    try s.endObject();
    try s.endObject();
}

/// The images of the tool results that end `upto`, as one user message.
fn toolImages(s: *Stringify, upto: []const Message) Stringify.Error!void {
    var start = upto.len;
    while (start > 0 and upto[start - 1].role == .tool_result) start -= 1;
    const group = upto[start..];
    for (group) |m| {
        if (hasImage(m)) break;
    } else return;
    try s.beginObject();
    try s.objectField("role");
    try s.write("user");
    try s.objectField("content");
    try s.beginArray();
    try s.write(.{ .type = "text", .text = "Attached image(s) from tool result:" });
    for (group) |m| for (m.content) |c| if (c == .image) try writeImage(s, c.image);
    try s.endArray();
    try s.endObject();
}

fn hasText(m: Message) bool {
    for (m.content) |c| if (c == .text) return true;
    return false;
}

fn hasToolCall(m: Message) bool {
    for (m.content) |c| if (c == .tool_call) return true;
    return false;
}

fn hasImage(m: Message) bool {
    for (m.content) |c| if (c == .image) return true;
    return false;
}

fn writeText(s: *Stringify, m: Message) Stringify.Error!void {
    try s.beginWriteRaw();
    try s.writer.writeByte('"');
    for (m.content) |c| if (c == .text) try Stringify.encodeJsonStringChars(c.text, .{}, s.writer);
    try s.writer.writeByte('"');
    s.endWriteRaw();
}

fn writeRaw(s: *Stringify, json: []const u8) Stringify.Error!void {
    try s.beginWriteRaw();
    try s.writer.writeAll(json);
    s.endWriteRaw();
}

test "encodes system, user, assistant tool calls and tool results" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(&out.writer, .{
        .model = "m",
        .session_id = "ses_1",
        .system = "sys",
        .messages = &.{
            .{ .id = "1", .role = .user, .content = &.{.{ .text = "hi \"there\"" }}, .timestamp = 0 },
            .{ .id = "2", .role = .assistant, .content = &.{
                .{ .thinking = .{ .text = "hidden" } },
                .{ .tool_call = .{ .id = "c1", .name = "read", .arguments = "{\"p\":1}" } },
            }, .timestamp = 0 },
            .{ .id = "3", .role = .tool_result, .content = &.{.{ .text = "ok" }}, .timestamp = 0, .toolCallId = "c1" },
            .{ .id = "4", .role = .assistant, .content = &.{}, .timestamp = 0, .stopReason = .@"error" },
            .{ .id = "5", .role = .assistant, .content = &.{.{ .thinking = .{ .text = "only thought" } }}, .timestamp = 0, .stopReason = .@"error" },
        },
    }, null);
    try std.testing.expectEqualStrings(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"system","content":"sys"},{"role":"user","content":"hi \"there\""},{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{\"p\":1}"}}]},{"role":"tool","tool_call_id":"c1","content":"ok"}]}
    , out.written());
}

test "user image and text become ordered OpenAI content parts" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(&out.writer, .{ .model = "vision", .thinking = .off, .system = "", .messages = &.{.{
        .id = "1",
        .role = .user,
        .timestamp = 0,
        .content = &.{ .{ .text = "look" }, .{ .image = .{ .mimeType = "image/png", .data = "YWJj" } } },
    }} }, "ses_1");
    try std.testing.expectEqualStrings(
        \\{"model":"vision","prompt_cache_key":"ses_1","reasoning_effort":"none","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"data:image/png;base64,YWJj"}}]}]}
    , out.written());
}

test "tool result images follow the group of tool messages as one user message" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(&out.writer, .{ .model = "m", .thinking = null, .system = "", .messages = &.{
        .{ .id = "1", .role = .tool_result, .timestamp = 0, .toolCallId = "a", .content = &.{ .{ .text = "Read image" }, .{ .image = .{ .mimeType = "image/png", .data = "AA==" } } } },
        .{ .id = "2", .role = .tool_result, .timestamp = 0, .toolCallId = "b", .content = &.{.{ .text = "ok" }} },
    } }, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(),
        \\{"role":"tool","tool_call_id":"a","content":"Read image"},{"role":"tool","tool_call_id":"b","content":"ok"},{"role":"user","content":[{"type":"text","text":"Attached image(s) from tool result:"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}]
    ) != null);
}
