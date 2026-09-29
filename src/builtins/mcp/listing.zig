//! Lists a server's tools and prompts and registers them, with its
//! instructions, as the plugin `mcp:<name>`.
const std = @import("std");
const Server = @import("Server.zig");
const rpc = @import("rpc.zig");
const names = @import("names.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Lists the tools and prompts (every page) and registers them, with the
/// server's instructions, in place of the old ones. A server whose prompts
/// cannot be listed keeps its tools.
pub fn refresh(s: *Server, link: *Server.Link) !void {
    const gpa = s.host.gpa;
    const version = try gpa.create(std.heap.ArenaAllocator);
    version.* = .init(gpa);
    var kept = false;
    defer if (!kept) {
        version.deinit();
        gpa.destroy(version);
    };
    const a = version.allocator();
    const listed = if (link.tools) try list(s, a, link, "tools/list", "tools") else &.{};
    const commands = if (link.prompts) prompts: {
        const items = list(s, a, link, "prompts/list", "prompts") catch |err| switch (err) {
            error.Canceled, error.McpUnauthorized => return err,
            else => {
                std.log.warn("mcp {s}: listing prompts failed: {s}", .{ s.spec.name, @errorName(err) });
                break :prompts &.{};
            },
        };
        break :prompts try @import("prompts.zig").build(a, s, items);
    } else &.{};
    const tools = try @import("tools.zig").build(a, s, listed);
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.closing or s.link != link) return error.Canceled;
    try s.versions.ensureUnusedCapacity(gpa, 1);
    const owner_id = try std.fmt.allocPrint(a, "mcp:{s}", .{s.spec.name});
    const owner = try s.host.registry.stage(.{
        .id = owner_id,
        .layer = .project,
        .location = s.location,
        .source = "mcp",
    }, s.owner);
    // The version's memory goes if this fails: so must the entries using it.
    errdefer s.host.registry.dispose(owner);
    var registered: usize = 0;
    for (tools) |tool| {
        s.host.registry.addTool(owner, tool) catch |err| {
            std.log.warn("mcp {s}: tool '{s}' skipped: {s}", .{ s.spec.name, tool.name, @errorName(err) });
            continue;
        };
        registered += 1;
    }
    for (commands) |command| s.host.registry.addCommand(owner, command) catch |err| {
        std.log.warn("mcp {s}: prompt '{s}' skipped: {s}", .{ s.spec.name, command.name, @errorName(err) });
    };
    // Only beside tools of this server the model is offered.
    if (s.spec.instructions and registered > 0 and link.instructions.len > 0) try s.host.registry.addSection(owner, .{
        .name = owner_id,
        .text = try std.fmt.allocPrint(a, "Instructions from the MCP server {s} (tools {s}*):\n{s}", .{ s.spec.name, try names.prefix(a, s.spec.name), cut(link.instructions, max_instructions) }),
    });
    s.versions.appendAssumeCapacity(version);
    kept = true;
    s.host.registry.commit(owner);
    s.owner = owner;
    s.tool_count = registered;
}

/// Every page of a list request's `key` array.
fn list(s: *Server, a: Allocator, link: *Server.Link, method: []const u8, key: []const u8) ![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    while (pages < 100) : (pages += 1) {
        const page = if (cursor) |c|
            try link.conn.request(a, method, .{ .cursor = c }, s.startup_ms, null)
        else
            try link.conn.request(a, method, rpc.empty, s.startup_ms, null);
        if (page != .object) return error.McpInvalidList;
        const items = page.object.get(key) orelse return error.McpInvalidList;
        if (items != .array) return error.McpInvalidList;
        try out.appendSlice(a, items.array.items);
        cursor = switch (page.object.get("nextCursor") orelse .null) {
            .string => |c| c,
            else => break,
        };
    }
    return out.items;
}

/// Instructions beyond this many bytes are cut.
const max_instructions = 2048;

fn cut(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

test cut {
    try std.testing.expectEqualStrings("ab", cut("ab", 5));
    // Never inside a character.
    try std.testing.expectEqualStrings("a", cut("a\u{e9}", 2));
}
