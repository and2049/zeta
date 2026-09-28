//! Per-location resources loaded beside the registry: discovered skills and
//! the `skill` tool that reads them, plus prompt-template commands.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const skills = @import("skills.zig");
const tool_skill = @import("tool_skill.zig");
const Allocator = std.mem.Allocator;

pub const Resources = struct {
    home: []const u8,
    config_dir: []const u8,

    /// Keep this stable in memory until Runtime.deinit returns. Its paths
    /// must also remain valid for that interval.
    pub fn resources(self: *Resources) core.Runtime.Resources {
        return .{ .ctx = self, .prepare = prepare, .inspect = inspect, .commands = commands };
    }

    fn commands(raw: ?*anyopaque, arena: Allocator, io: std.Io, location: []const u8) anyerror!core.commands.Listing {
        const self: *Resources = @ptrCast(@alignCast(raw.?));
        return @import("prompts.zig").discover(arena, io, self.home, self.config_dir, location);
    }

    fn prepare(raw: ?*anyopaque, arena: Allocator, io: std.Io, location: []const u8, _: core.config.Config, _: []const plugin.tool.Tool) anyerror!core.Runtime.Prepared {
        const self: *Resources = @ptrCast(@alignCast(raw.?));
        const discovered = try skills.discover(arena, io, self.home, self.config_dir, location);
        const ctx = try arena.create(tool_skill.Context);
        ctx.* = .{ .discovered = discovered };
        var sections: std.ArrayList(core.prompt.Section) = .empty;
        if (discovered.len != 0) try sections.append(arena, .{ .name = "available skills", .text = try skills.promptMetadata(arena, discovered) });
        return .{
            .plugin = "skills",
            .tools = try arena.dupe(plugin.tool.Tool, &.{tool_skill.tool(ctx)}),
            .sections = sections.items,
        };
    }

    /// Registry listing entries; the result is wholly arena owned.
    fn inspect(raw: ?*anyopaque, arena: Allocator, io: std.Io, _: core.config.Config, location: []const u8) anyerror!std.json.Value {
        const self: *Resources = @ptrCast(@alignCast(raw.?));
        const discovered = try skills.discover(arena, io, self.home, self.config_dir, location);
        return std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, .{ .skills = discovered }, .{}), .{ .allocate = .alloc_always });
    }
};

test "prepare offers the skill tool" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = buf[0..try tmp.dir.realPath(io, &buf)];
    var self: Resources = .{ .home = directory, .config_dir = directory };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const resource = self.resources();
    const prepared = try resource.prepare(resource.ctx, arena_state.allocator(), io, directory, .{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), prepared.tools.len);
    try std.testing.expectEqualStrings("skill", prepared.tools[0].name);
}
