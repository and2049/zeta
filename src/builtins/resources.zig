//! Per-location resources loaded beside the registry: discovered skills plus
//! the built-in `zeta` docs index skill (and the `skill` tool that reads
//! them), prompt-template commands and the self-docs prompt section.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const skills = @import("skills.zig");
const tool_skill = @import("tool_skill.zig");
const docs = @import("docs.zig");
const Allocator = std.mem.Allocator;

pub const Resources = struct {
    home: []const u8,
    config_dir: []const u8,
    docs_dir: ?[]const u8 = null,

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
        const discovered = try self.available(arena, io, location);
        const ctx = try arena.create(tool_skill.Context);
        ctx.* = .{ .discovered = discovered };
        var sections: std.ArrayList(core.prompt.Section) = .empty;
        if (discovered.len != 0) try sections.append(arena, .{ .name = "available skills", .text = try skills.promptMetadata(arena, discovered) });
        if (self.docs_dir) |directory| try sections.append(arena, .{ .name = "zeta documentation", .text = try std.fmt.allocPrint(
            arena,
            "zeta documentation (read only when the user asks about zeta itself, its config, plugins, extensions, skills, or TUI, or asks to extend or change zeta): {s}/README.md, {s}/*.md, examples: {s}/examples/. Read files completely and follow links before changing zeta.",
            .{ directory, directory, directory },
        ) });
        return .{
            .plugin = "skills",
            .tools = try arena.dupe(plugin.tool.Tool, &.{tool_skill.tool(ctx)}),
            .sections = sections.items,
        };
    }

    /// Registry listing entries; the result is wholly arena owned.
    fn inspect(raw: ?*anyopaque, arena: Allocator, io: std.Io, _: core.config.Config, location: []const u8) anyerror!std.json.Value {
        const self: *Resources = @ptrCast(@alignCast(raw.?));
        const discovered = try self.available(arena, io, location);
        return std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, .{ .skills = discovered }, .{}), .{ .allocate = .alloc_always });
    }

    /// Discovered skills plus the built-in `zeta` index over the materialized
    /// docs; a discovered skill with the same name replaces it.
    fn available(self: *Resources, arena: Allocator, io: std.Io, location: []const u8) ![]const skills.Skill {
        const discovered = try skills.discover(arena, io, self.home, self.config_dir, location);
        const directory = self.docs_dir orelse return discovered;
        const builtin = (try skills.parse(arena, index, try std.fs.path.join(arena, &.{ directory, "SKILL.md" }))) orelse return error.InvalidDocsSkill;
        for (discovered) |skill| if (std.mem.eql(u8, skill.name, builtin.name)) return discovered;
        var list: std.ArrayList(skills.Skill) = .empty;
        try list.append(arena, builtin);
        try list.appendSlice(arena, discovered);
        std.mem.sort(skills.Skill, list.items, {}, struct {
            fn less(_: void, a: skills.Skill, b: skills.Skill) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        return list.items;
    }
};

const index = blk: {
    for (docs.files) |file| {
        if (std.mem.eql(u8, file.name, "SKILL.md")) break :blk file.content;
    }
    @compileError("docs/SKILL.md is not embedded");
};

test "the docs index is a valid skill named zeta" {
    const skill = (try skills.parse(std.testing.allocator, index, "SKILL.md")).?;
    try std.testing.expectEqualStrings("zeta", skill.name);
}

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

test "the zeta skill loads the docs index unless a discovered skill replaces it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "SKILL.md", .data = index });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = buf[0..try tmp.dir.realPath(io, &buf)];
    var self: Resources = .{ .home = directory, .config_dir = directory, .docs_dir = directory };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "name", .{ .string = "zeta" });

    const resource = self.resources();
    var prepared = try resource.prepare(resource.ctx, arena, io, directory, .{}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, prepared.sections[0].text, "- zeta: ") != null);
    var result = try prepared.tools[0].execute(prepared.tools[0].ctx, arena, io, directory, .{ .object = args }, undefined);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "zeta documentation index") != null);

    _ = try tmp.dir.createDirPathStatus(io, ".zeta/skills/zeta", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".zeta/skills/zeta/SKILL.md", .data = "---\nname: zeta\ndescription: mine\n---\nPROJECT" });
    prepared = try resource.prepare(resource.ctx, arena, io, directory, .{}, &.{});
    result = try prepared.tools[0].execute(prepared.tools[0].ctx, arena, io, directory, .{ .object = args }, undefined);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "PROJECT"));
}
