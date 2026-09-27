//! What a run at one location gets: registered tools, prompt sections,
//! and the assembled system prompt.
//! Runs and `/registry` both build it here, so the listing is what a run sees.
const std = @import("std");
const plugin = @import("plugin");
const Runtime = @import("Runtime.zig");
const config = @import("config.zig");
const prompt = @import("prompt.zig");
const runtime_tools = @import("runtime_tools.zig");
const plugin_config = @import("plugin_config.zig");
const Allocator = std.mem.Allocator;

pub const View = struct {
    registry: plugin.Registry.View,
    /// Registered tools; timeouts filled in.
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
    const tools = try registry.toolValues(arena);
    runtime_tools.applyTimeouts(tools, cfg.tool_timeout_ms);
    const sources = try arena.alloc([]const u8, tools.len);
    for (registry.tools, sources) |entry, *source| source.* = entry.plugin;

    var sections: std.ArrayList(prompt.Section) = .empty;
    try sections.appendSlice(arena, &.{
        .{ .name = "base", .text = prompt.base },
        .{ .name = "environment", .text = try prompt.environment(arena, location) },
    });
    for (registry.sections) |entry| try sections.append(arena, .{ .name = entry.value.name, .text = entry.value.text });
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
