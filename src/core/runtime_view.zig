//! What a run at one location gets: registered tools, tools and prompt
//! sections from the resource loaders, and the assembled system prompt.
//! Runs and `/registry` both build it here, so the listing is what a run sees.
const std = @import("std");
const plugin = @import("plugin");
const Runtime = @import("Runtime.zig");
const config = @import("config.zig");
const prompt = @import("prompt.zig");
const instructions = @import("instructions.zig");
const runtime_tools = @import("runtime_tools.zig");
const plugin_config = @import("plugin_config.zig");
const Allocator = std.mem.Allocator;

pub const View = struct {
    registry: plugin.Registry.View,
    /// Registered tools, then the loaders' tools; timeouts filled in.
    tools: []plugin.tool.Tool,
    /// The plugin that provided each tool, in the same order.
    sources: []const []const u8,
    sections: []const prompt.Section,
    system: []const u8,
    /// Config problems: unknown keys, config for missing plugins, and
    /// plugin config failing its schema (which sets `config_invalid`); then
    /// plugins that failed to load.
    diagnostics: []const []const u8,
    config_invalid: bool,
};

/// Everything returned lives in `arena`.
pub fn assemble(rt: *Runtime, arena: Allocator, location: []const u8, cfg: config.Config) !View {
    _ = try rt.registry.activate(arena, location);
    const registry = try rt.registry.view(arena, location);
    const report = try plugin_config.check(arena, cfg, registry.plugins);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    try diagnostics.appendSlice(arena, report.diagnostics);
    for (registry.problems) |p| try diagnostics.append(arena, try std.fmt.allocPrint(arena, "plugin '{s}': {s}", .{ p.plugin, p.message }));
    const registered = try registry.toolValues(arena);
    const prepared = if (rt.resources) |loader| try loader.prepare(loader.ctx, arena, rt.io, location, cfg, registered) else Runtime.Prepared{};
    try runtime_tools.validatePrepared(arena, registered, prepared.tools);
    var offered: std.ArrayList(plugin.tool.Tool) = .empty;
    for (registered) |tool| if (cfg.inspect_tool or !isInspect(tool.name)) try offered.append(arena, tool);
    const tools = try std.mem.concat(arena, plugin.tool.Tool, &.{ offered.items, prepared.tools });
    runtime_tools.applyTimeouts(tools, cfg.tool_timeout_ms);
    const sources = try arena.alloc([]const u8, tools.len);
    var index: usize = 0;
    for (registry.tools) |entry| {
        if (!cfg.inspect_tool and isInspect(entry.value.name)) continue;
        sources[index] = entry.plugin;
        index += 1;
    }
    for (sources[index..]) |*source| source.* = prepared.plugin;

    var sections: std.ArrayList(prompt.Section) = .empty;
    try sections.appendSlice(arena, &.{
        .{ .name = "base", .text = prompt.base },
        .{ .name = "environment", .text = try prompt.environment(arena, location) },
    });
    for (try instructions.collect(arena, rt.io, rt.config_dir, location)) |item| {
        try sections.append(arena, .{ .name = item.path, .text = item.text });
    }
    for (registry.sections) |entry| try sections.append(arena, .{ .name = entry.value.name, .text = entry.value.text });
    try sections.appendSlice(arena, prepared.sections);
    return .{
        .registry = registry,
        .tools = tools,
        .sources = sources,
        .sections = sections.items,
        .system = try prompt.build(arena, sections.items),
        .diagnostics = diagnostics.items,
        .config_invalid = report.invalid,
    };
}

fn isInspect(name: []const u8) bool {
    return std.mem.eql(u8, name, "zeta_inspect");
}
