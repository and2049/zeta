//! Turns a model reference into a transport through the provider registered
//! for it. Runs, titles and image admission all route the same way.
const std = @import("std");
const plugin = @import("plugin");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Routed = struct {
    api: plugin.provider.Api,
    options: plugin.provider.Options,
};

/// Everything returned lives in `arena`.
pub fn resolve(view: plugin.Registry.View, arena: Allocator, io: Io, cfg: config.Config, provider: []const u8, model: []const u8) !Routed {
    const entry = view.provider(provider) orelse return error.ProviderNotFound;
    var q = try query(arena, cfg, provider, model);
    q.plugin_options = cfg.pluginOptions(entry.plugin) orelse .null;
    const route = try entry.value.resolve(entry.value.ctx, arena, io, q);
    return .{ .api = view.api(route.api) orelse return error.ProviderApiMissing, .options = route.options };
}

/// Picker entries from every registered provider, in registration order.
pub fn models(view: plugin.Registry.View, arena: Allocator, io: Io, cfg: config.Config) ![]const std.json.Value {
    var out: std.ArrayList(std.json.Value) = .empty;
    for (view.providers) |entry| {
        const list = entry.value.models orelse continue;
        var q = try query(arena, cfg, entry.value.id, "");
        q.plugin_options = cfg.pluginOptions(entry.plugin) orelse .null;
        try out.appendSlice(arena, try list(entry.value.ctx, arena, io, q));
    }
    return out.items;
}

pub fn query(arena: Allocator, cfg: config.Config, provider: []const u8, model: []const u8) !plugin.provider.Query {
    const configured = try arena.alloc(plugin.provider.Configured, cfg.provider.map.count());
    var it = cfg.provider.map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        var raw_models: std.json.ObjectMap = .empty;
        var model_it = entry.value_ptr.models.map.iterator();
        while (model_it.next()) |m| try raw_models.put(arena, m.key_ptr.*, m.value_ptr.*);
        const options = entry.value_ptr.options;
        configured[i] = .{ .id = entry.key_ptr.*, .baseURL = options.baseURL, .apiKey = options.apiKey, .setCacheKey = options.setCacheKey, .models = .{ .object = raw_models } };
    }
    return .{ .provider = provider, .model = model, .configured = configured };
}

test "query carries every configured provider" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: config.Config = .{};
    var local: config.Provider = .{ .options = .{ .baseURL = "http://local", .apiKey = "k" } };
    try local.models.map.put(a, "m", .{ .bool = true });
    try cfg.provider.map.put(a, "local", local);
    const q = try query(a, cfg, "local", "m");
    try std.testing.expectEqualStrings("http://local", q.options("local").baseURL.?);
    try std.testing.expectEqualStrings("k", q.options("local").apiKey.?);
    try std.testing.expect(q.options("local").models.object.get("m").?.bool);
    try std.testing.expect(q.options("other").baseURL == null);
}

/// The thinking level a run asks for: the session's selection, else the
/// model's configured default, else the config's; fitted to the levels the
/// model takes. Null (no setting sent) for a model that does not reason, or
/// when nothing is chosen.
pub fn thinkingLevel(selected: ?[]const u8, options: plugin.provider.Options, configured: ?[]const u8) ?thinking.Level {
    if (!options.reasoning) return null;
    const wanted = parse(selected) orelse options.thinking orelse parse(configured) orelse return null;
    return thinking.clamp(wanted, options.thinking_levels orelse .initFull());
}

fn parse(text: ?[]const u8) ?thinking.Level {
    return thinking.Level.parse(text orelse return null);
}

const thinking = @import("proto").thinking;

test thinkingLevel {
    const reasoning: plugin.provider.Options = .{ .reasoning = true, .thinking = .low, .thinking_levels = .initMany(&.{ .low, .high }) };
    try std.testing.expectEqual(thinking.Level.high, thinkingLevel("medium", reasoning, "off").?);
    try std.testing.expectEqual(thinking.Level.low, thinkingLevel(null, reasoning, "high").?);
    try std.testing.expectEqual(thinking.Level.xhigh, thinkingLevel(null, .{ .reasoning = true }, "xhigh").?);
    try std.testing.expect(thinkingLevel(null, .{ .reasoning = true }, null) == null);
    try std.testing.expect(thinkingLevel("high", .{}, "high") == null);
}
