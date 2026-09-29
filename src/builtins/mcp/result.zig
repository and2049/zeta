//! What the model gets from a `tools/call` result.
const std = @import("std");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Text for the model from a `tools/call` result.
pub fn format(arena: Allocator, result: Value) !plugin.tool.Result {
    if (result != .object) return .{ .text = "", .isError = true };
    const o = result.object;
    var out: std.ArrayList(u8) = .empty;
    if (o.get("content")) |content| if (content == .array) for (content.array.items) |item| {
        const text = try part(arena, item) orelse continue;
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, text);
    };
    if (out.items.len == 0) if (o.get("structuredContent")) |structured| {
        try out.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, structured, .{}));
    };
    const is_error = if (o.get("isError")) |e| e == .bool and e.bool else false;
    return .{ .text = out.items, .isError = is_error };
}

/// Text for one content item: its text, an embedded resource's text, or a
/// short placeholder (`[image image/png]`). Null for what is not content.
pub fn part(arena: Allocator, item: Value) !?[]const u8 {
    if (item != .object) return null;
    const p = item.object;
    const kind = switch (p.get("type") orelse .null) {
        .string => |t| t,
        else => return null,
    };
    if (std.mem.eql(u8, kind, "text")) return if (p.get("text")) |t| if (t == .string) t.string else "" else "";
    if (std.mem.eql(u8, kind, "resource")) {
        const resource = p.get("resource") orelse .null;
        if (resource == .object) if (resource.object.get("text")) |t| if (t == .string) return t.string;
        return try std.fmt.allocPrint(arena, "[resource {s}]", .{field(resource, "uri")});
    }
    if (std.mem.eql(u8, kind, "resource_link")) return try std.fmt.allocPrint(arena, "[resource link {s}]", .{field(item, "uri")});
    return try std.fmt.allocPrint(arena, "[{s} {s}]", .{ kind, field(item, "mimeType") });
}

fn field(v: Value, name: []const u8) []const u8 {
    if (v != .object) return "";
    return switch (v.object.get(name) orelse .null) {
        .string => |s| s,
        else => "",
    };
}

test "tool results become text for the model" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"content":[{"type":"text","text":"one"},{"type":"image","mimeType":"image/png","data":"x"},
        \\ {"type":"resource","resource":{"uri":"file:///a","text":"body"}},{"type":"resource_link","uri":"file:///b"}],"isError":true}
    , .{});
    const r = try format(a, v);
    try std.testing.expectEqualStrings("one\n[image image/png]\nbody\n[resource link file:///b]", r.text);
    try std.testing.expect(r.isError);
    const structured = try format(a, try std.json.parseFromSliceLeaky(Value, a, "{\"content\":[],\"structuredContent\":{\"n\":1}}", .{}));
    try std.testing.expectEqualStrings("{\"n\":1}", structured.text);
}
