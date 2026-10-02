const std = @import("std");
const plugin = @import("plugin");
const skills = @import("skills.zig");

pub const Context = struct {
    /// Borrowed snapshot from discovery, valid through this tool's turn.
    discovered: []const skills.Skill,
};

/// Caller owns Context and discovered arena through all per-turn tool calls.
pub fn tool(ctx: *Context) plugin.tool.Tool {
    return .{
        .name = "skill",
        .description = "Load the full instructions for a discovered skill by name.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"],\"additionalProperties\":false}",
        .side_effect = .read,
        .ctx = ctx,
        .execute = execute,
    };
}

fn execute(raw: ?*anyopaque, arena: std.mem.Allocator, io: std.Io, _: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    const ctx: *Context = @ptrCast(@alignCast(raw orelse return error.MissingContext));
    if (args != .object) return .{ .text = "Expected skill name", .isError = true };
    const name = args.object.get("name") orelse return .{ .text = "Expected skill name", .isError = true };
    if (name != .string) return .{ .text = "Expected skill name", .isError = true };
    for (ctx.discovered) |skill| {
        if (!std.mem.eql(u8, skill.name, name.string)) continue;
        // Never construct a path from model input; only open a discovered path.
        const content = std.Io.Dir.cwd().readFileAlloc(io, skill.path, arena, .limited(1024 * 1024)) catch return .{ .text = "Could not read skill", .isError = true };
        const body = bodyAfterFrontmatter(content) orelse return .{ .text = "Skill frontmatter changed or is invalid", .isError = true };
        return .{ .text = try std.fmt.allocPrint(arena, "Skill: {s}\nBase directory: {s}\n\n{s}", .{ skill.name, std.fs.path.dirname(skill.path) orelse ".", body }) };
    }
    return .{ .text = "Unknown skill", .isError = true };
}

fn bodyAfterFrontmatter(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "---\n") and !std.mem.startsWith(u8, text, "---\r\n")) return null;
    var pos = std.mem.indexOfScalar(u8, text, '\n').? + 1;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        if (std.mem.eql(u8, std.mem.trim(u8, text[pos..end], " \r\t"), "---")) return std.mem.trim(u8, text[@min(end + 1, text.len)..], "\n\r");
        pos = end + 1;
    }
    return null;
}

test "skill body remains lazy" {
    try std.testing.expectEqualStrings("secret", bodyAfterFrontmatter("---\nname: x\n---\nsecret").?);
    try std.testing.expect(bodyAfterFrontmatter("bad") == null);
}

test "unknown names never become filesystem paths" {
    var ctx: Context = .{ .discovered = &.{} };
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "name", .{ .string = "../../secret" });
    const t = tool(&ctx);
    const result = try t.execute(t.ctx, std.testing.allocator, std.testing.io, ".", .{ .object = args }, undefined);
    try std.testing.expect(result.isError);
}
