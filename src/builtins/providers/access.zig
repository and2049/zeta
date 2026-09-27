//! Picker visibility follows credential precedence without exposing secrets.
const std = @import("std");
const plugin = @import("plugin");
const platform = @import("platform");
const models = @import("../models.zig");

/// Whether `id`'s stored credential is a sign-in. `configured_key`
/// (`provider.<id>.options.apiKey`) always wins over it.
pub fn usesOAuth(id: []const u8, configured_key: ?[]const u8, saved: []const platform.credentials.Metadata) bool {
    if (configured_key != null) return false;
    for (saved) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return std.mem.eql(u8, entry.type, "oauth");
    }
    return false;
}

pub fn connected(
    arena: std.mem.Allocator,
    options: plugin.provider.Configured,
    provider: models.Provider,
    env: *const std.process.Environ.Map,
    saved: []const platform.credentials.Metadata,
    /// The provider accepts a stored sign-in.
    oauth: bool,
) !bool {
    // An explicitly configured endpoint can deliberately require no key.
    if (options.baseURL) |url| if (url.len > 0) return true;
    // Empty config values mask lower-precedence stored/environment keys too.
    if (options.apiKey) |key| return key.len > 0;
    for (saved) |entry| {
        if (!std.mem.eql(u8, entry.id, provider.id)) continue;
        if (std.mem.eql(u8, entry.type, "api")) return true;
        if (oauth and std.mem.eql(u8, entry.type, "oauth")) return true;
    }
    for (provider.env) |name| if (env.get(name)) |value| return value.len > 0;
    const name = try std.fmt.allocPrint(arena, "{s}_API_KEY", .{provider.id});
    for (name) |*ch| ch.* = if (ch.* == '-') '_' else std.ascii.toUpper(ch.*);
    return if (env.get(name)) |value| value.len > 0 else false;
}

test "picker visibility respects credentials and explicit keyless endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const openai: models.Provider = .{ .id = "openai", .name = "OpenAI", .env = &.{"OPENAI_API_KEY"} };
    const stored: []const platform.credentials.Metadata = &.{.{ .id = "openai", .type = "oauth" }};
    try std.testing.expect(!try connected(a, .{ .id = "" }, openai, &env, &.{}, true));
    try std.testing.expect(try connected(a, .{ .id = "" }, openai, &env, stored, true));
    try env.put("OPENAI_API_KEY", "environment-key");
    try std.testing.expect(try connected(a, .{ .id = "" }, openai, &env, &.{}, true));
    var cfg: plugin.provider.Configured = .{ .id = "" };
    cfg.apiKey = "";
    try std.testing.expect(!try connected(a, cfg, openai, &env, stored, true));
    cfg.apiKey = "configured";
    try std.testing.expect(try connected(a, cfg, openai, &env, &.{}, true));
    const local: models.Provider = .{ .id = "local", .name = "Local" };
    try std.testing.expect(!try connected(a, .{ .id = "local" }, local, &env, &.{}, false));
    try std.testing.expect(try connected(a, .{ .id = "local", .baseURL = "http://127.0.0.1:8080/v1" }, local, &env, &.{}, false));
    const deepseek: models.Provider = .{ .id = "deepseek", .name = "DeepSeek" };
    try std.testing.expect(!try connected(a, .{ .id = "deepseek" }, deepseek, &env, stored, false));
    try std.testing.expect(try connected(a, .{ .id = "deepseek" }, deepseek, &env, &.{.{ .id = "deepseek", .type = "api" }}, false));
    const glm: models.Provider = .{ .id = "zai", .name = "Z.AI", .env = &.{"ZHIPU_API_KEY"} };
    try env.put("ZHIPU_API_KEY", "glm-key");
    try std.testing.expect(try connected(a, .{ .id = "zai" }, glm, &env, &.{}, false));
}
