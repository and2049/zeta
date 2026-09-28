//! `zeta_inspect`: the live registry and config for the call's location, so
//! the agent can check real state instead of trusting the docs.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");

pub const Inspector = struct {
    /// Set by the composition root once the runtime exists; until then the
    /// tool reports that nothing is available.
    runtime: ?*core.Runtime = null,
};

pub fn tool(ctx: *Inspector) plugin.tool.Tool {
    return .{
        .name = "zeta_inspect",
        .description = "Inspect zeta's live state for this project: plugins, tools, hooks, providers, the effective config with the source of each value, and diagnostics. Call without arguments for a summary, then ask for one section.",
        .input_schema = comptime schema(),
        .side_effect = .read,
        .ctx = ctx,
        .execute = execute,
    };
}

fn schema() []const u8 {
    var names: []const u8 = "";
    for (std.enums.values(core.inspect.Section), 0..) |s, i| names = names ++ (if (i == 0) "" else ",") ++ "\"" ++ @tagName(s) ++ "\"";
    return "{\"type\":\"object\",\"properties\":{\"section\":{\"type\":\"string\",\"enum\":[" ++ names ++ "]}},\"additionalProperties\":false}";
}

fn execute(raw: ?*anyopaque, arena: std.mem.Allocator, io: std.Io, location: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    const self: *Inspector = @ptrCast(@alignCast(raw orelse return error.MissingContext));
    const rt = self.runtime orelse return .{ .text = "Inspection is not available in this process.", .isError = true };
    var which: core.inspect.Section = .summary;
    if (args == .object) if (args.object.get("section")) |value| if (value == .string) {
        which = std.meta.stringToEnum(core.inspect.Section, value.string) orelse return .{ .text = "Unknown section", .isError = true };
    };
    const cfg = try core.config.load(arena, io, rt.env, rt.config_dir, location);
    const result = try core.inspect.section(rt, arena, location, cfg, which);
    return .{ .text = try std.json.Stringify.valueAlloc(arena, result, .{}) };
}

test "without a runtime the tool reports an error instead of failing" {
    var inspector: Inspector = .{};
    const t = tool(&inspector);
    const result = try t.execute(t.ctx, std.testing.allocator, std.testing.io, ".", .null, undefined);
    try std.testing.expect(result.isError);
}

test "the schema lists every section" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, comptime schema(), .{});
    defer parsed.deinit();
    const names = parsed.value.object.get("properties").?.object.get("section").?.object.get("enum").?.array.items;
    try std.testing.expectEqual(std.enums.values(core.inspect.Section).len, names.len);
    try std.testing.expectEqualStrings("summary", names[0].string);
}
