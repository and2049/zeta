//! One-line summaries for tool calls: the argument that says what the call
//! does (a path, a command, a URL). Any other tool shows its first string
//! argument.
const std = @import("std");
const plugin = @import("../plugin.zig");

pub const plugin_entry: plugin.Plugin = .{ .id = "tools", .setup = setup };

fn setup(r: *plugin.Registry) anyerror!void {
    inline for (.{
        .{ "read", "path" },
        .{ "write", "path" },
        .{ "edit", "path" },
        .{ "bash", "command" },
        .{ "webfetch", "url" },
        .{ "skill", "name" },
    }) |spec| try r.addToolRenderer(.{ .tool = spec[0], .summary = field(spec[1]) });
    try r.addToolRenderer(.{ .tool = "*", .summary = firstString });
}

fn field(comptime name: []const u8) *const fn (std.mem.Allocator, []const u8) anyerror![]const u8 {
    return struct {
        fn summary(a: std.mem.Allocator, arguments: []const u8) anyerror![]const u8 {
            const value = parse(a, arguments) orelse return "";
            if (value.object.get(name)) |v| if (v == .string) return oneLine(v.string);
            return firstString(a, arguments);
        }
    }.summary;
}

fn firstString(a: std.mem.Allocator, arguments: []const u8) anyerror![]const u8 {
    const value = parse(a, arguments) orelse return "";
    var it = value.object.iterator();
    while (it.next()) |entry| if (entry.value_ptr.* == .string) return oneLine(entry.value_ptr.string);
    return "";
}

fn parse(a: std.mem.Allocator, arguments: []const u8) ?std.json.Value {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, arguments, .{}) catch return null;
    return if (value == .object) value else null;
}

fn oneLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
}

test "summaries pick the telling argument" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = try plugin.Registry.init(std.testing.allocator, &.{plugin_entry});
    defer r.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/a.zig", try r.toolRenderer("read").?.summary(a, "{\"offset\":1,\"path\":\"src/a.zig\"}"));
    try std.testing.expectEqualStrings("ls -la", try r.toolRenderer("bash").?.summary(a, "{\"command\":\"ls -la\\necho\"}"));
    try std.testing.expectEqualStrings("q", try r.toolRenderer("mcp__x__search").?.summary(a, "{\"n\":2,\"query\":\"q\"}"));
    try std.testing.expectEqualStrings("", try r.toolRenderer("read").?.summary(a, "not json"));
}
