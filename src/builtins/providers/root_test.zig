const std = @import("std");
const plugin = @import("plugin");
const platform = @import("platform");
const models = @import("../models.zig");
const providers = @import("root.zig");
const Configured = plugin.provider.Configured;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,
    catalog: *models.Catalog,
    env: std.process.Environ.Map,
    registry: plugin.Registry,
    providers: providers.Context,
    arena: std.heap.ArenaAllocator,
    buf: [std.Io.Dir.max_path_bytes]u8,

    fn init(self: *Fixture, catalog_json: ?[]const u8) !void {
        const a = std.testing.allocator;
        const io = std.testing.io;
        self.tmp = std.testing.tmpDir(.{});
        if (catalog_json) |data| try self.tmp.dir.writeFile(io, .{ .sub_path = "models.json", .data = data });
        self.dir = self.buf[0..try self.tmp.dir.realPath(io, &self.buf)];
        self.catalog = try models.Catalog.init(a, io, .{ .keep = providers.catalog_ids, .cache_dir = self.dir, .refresh = false });
        self.env = .init(a);
        self.registry = .init(a, io);
        self.providers = .{ .env = &self.env, .catalog = self.catalog };
        try providers.register(&self.providers, &self.registry);
        self.arena = .init(a);
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.registry.deinit();
        self.env.deinit();
        self.catalog.deinit();
        self.tmp.cleanup();
    }

    fn route(self: *Fixture, configured: []const Configured, provider: []const u8, model: []const u8) !plugin.provider.Route {
        const a = self.arena.allocator();
        const entry = (try self.registry.view(a, null)).provider(provider).?.value;
        return entry.resolve(entry.ctx, a, std.testing.io, .{ .provider = provider, .model = model, .configured = configured });
    }

    fn list(self: *Fixture, configured: []const Configured, provider: []const u8) ![]const std.json.Value {
        const a = self.arena.allocator();
        const entry = (try self.registry.view(a, null)).provider(provider).?.value;
        return entry.models.?(entry.ctx, a, std.testing.io, .{ .provider = provider, .model = "", .configured = configured });
    }
};

test "supported providers register in order with their login methods, then the fallback" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const view = try f.registry.view(f.arena.allocator(), null);
    const ids = [_][]const u8{ "openai", "anthropic", "deepseek", "zai", "zhipuai", "openrouter", "*" };
    try std.testing.expectEqual(ids.len, view.providers.len);
    for (ids, view.providers) |id, p| try std.testing.expectEqualStrings(id, p.value.id);
    try std.testing.expectEqualStrings("custom", view.providers[6].plugin);
    try std.testing.expectEqual(@as(usize, 3), view.providers[0].value.auth_methods.len);
    for (view.providers[1..]) |p| try std.testing.expectEqual(@as(usize, 1), p.value.auth_methods.len);
}

test "catalog URL and env names apply, with explicit config and stored keys first" {
    var f: Fixture = undefined;
    try f.init(
        \\{"deepseek":{"api":"https://catalog.test/v1","env":["EXAMPLE_TOKEN"],"models":{"vision":{"name":"Vision","modalities":{"input":["text","image"]}}}}}
    );
    defer f.deinit();
    try f.env.put("EXAMPLE_TOKEN", "env-secret");
    const result = try f.route(&.{}, "deepseek", "one");
    try std.testing.expectEqualStrings("openai-compatible", result.api);
    try std.testing.expectEqualStrings("https://catalog.test/v1", result.options.baseURL.?);
    try std.testing.expectEqualStrings("env-secret", result.options.apiKey.?);
    try std.testing.expect(!result.options.accepts_images);
    try std.testing.expect((try f.route(&.{}, "deepseek", "vision")).options.accepts_images);
    const explicit: []const Configured = &.{.{ .id = "deepseek", .baseURL = "https://configured.test/v1", .apiKey = "config-secret" }};
    const configured = try f.route(explicit, "deepseek", "one");
    try std.testing.expectEqualStrings("https://configured.test/v1", configured.options.baseURL.?);
    try std.testing.expectEqualStrings("config-secret", configured.options.apiKey.?);
    f.providers.data_dir = f.dir;
    try platform.credentials.putApiKey(f.arena.allocator(), std.testing.io, f.dir, "deepseek", "stored-secret");
    try std.testing.expectEqualStrings("stored-secret", (try f.route(&.{}, "deepseek", "one")).options.apiKey.?);
    try std.testing.expectEqualStrings("config-secret", (try f.route(explicit, "deepseek", "one")).options.apiKey.?);
    // Only OpenAI sends a prompt-cache key unless config asks for one.
    try std.testing.expect(!configured.options.cache_key);
    try std.testing.expect((try f.route(&.{.{ .id = "deepseek", .baseURL = "https://configured.test/v1", .setCacheKey = true }}, "deepseek", "one")).options.cache_key);
    try std.testing.expect((try f.route(&.{}, "openai", "one")).options.cache_key);
    try std.testing.expect(!(try f.route(&.{.{ .id = "openai", .setCacheKey = false }}, "openai", "one")).options.cache_key);
}

test "anthropic routes to the Messages transport with the model's output limit" {
    var f: Fixture = undefined;
    try f.init(
        \\{"anthropic":{"env":["ANTHROPIC_API_KEY"],"models":{"claude-x":{"name":"Claude X","limit":{"context":200000,"output":64000}}}}}
    );
    defer f.deinit();
    try f.env.put("ANTHROPIC_API_KEY", "sk-ant-env");
    const result = try f.route(&.{}, "anthropic", "claude-x");
    try std.testing.expectEqualStrings("anthropic-messages", result.api);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1", result.options.baseURL.?);
    try std.testing.expectEqualStrings("sk-ant-env", result.options.apiKey.?);
    try std.testing.expectEqual(@as(u64, 200000), result.options.context_window);
    try std.testing.expectEqual(@as(u64, 64000), result.options.max_output);
    try std.testing.expectEqual(@as(u64, 0), (try f.route(&.{}, "anthropic", "other")).options.max_output);
}

test "without a catalog entry named providers use their own endpoint and custom ones need config" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    f.providers.data_dir = f.dir;
    try f.env.put("OPENAI_API_KEY", "openai-key");
    try platform.credentials.putApiKey(f.arena.allocator(), std.testing.io, f.dir, "deepseek", "deepseek-secret");
    const offline = try f.route(&.{}, "deepseek", "deepseek-chat");
    try std.testing.expectEqualStrings("https://api.deepseek.com", offline.options.baseURL.?);
    try std.testing.expectEqualStrings("deepseek-secret", offline.options.apiKey.?);
    const openai = try f.route(&.{}, "openai", "gpt-4.1");
    try std.testing.expect(openai.options.baseURL == null);
    try std.testing.expectEqualStrings("openai-key", openai.options.apiKey.?);
    const configured = try f.route(&.{.{ .id = "deepseek", .baseURL = "https://configured.test/v1" }}, "deepseek", "deepseek-chat");
    try std.testing.expectEqualStrings("https://configured.test/v1", configured.options.baseURL.?);
    try std.testing.expectEqualStrings("deepseek-secret", configured.options.apiKey.?);
    // Custom providers take their endpoint and image support from config.
    try std.testing.expectError(error.ProviderEndpointUnknown, f.route(&.{}, "local", "m"));
    const models_json = try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(),
        \\{"m":{"modalities":{"input":["text","image"]}}}
    , .{});
    const local = try f.route(&.{.{ .id = "local", .baseURL = "http://127.0.0.1:8080/v1", .models = models_json }}, "local", "m");
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1", local.options.baseURL.?);
    try std.testing.expect(local.options.accepts_images);
    const listed = try f.list(&.{.{ .id = "local", .baseURL = "http://127.0.0.1:8080/v1", .models = models_json }}, "*");
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("local", listed[0].object.get("id").?.string);
}

test "a ChatGPT sign-in routes OpenAI to Codex and an explicit key overrides it" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const a = std.testing.allocator;
    const io = std.testing.io;
    f.providers.data_dir = f.dir;
    try f.env.put("OPENAI_API_KEY", "environment-key");
    try platform.credentials.putOAuth(a, io, f.dir, "openai", .{ .access = "expired-access", .refresh = "refresh-secret", .expires = 0, .account_id = "account" });
    const oauth = try f.route(&.{}, "openai", "gpt-5.5");
    try std.testing.expectEqualStrings("openai-codex", oauth.api);
    try std.testing.expect(oauth.options.authentication != null);
    try std.testing.expect(oauth.options.apiKey == null);
    try std.testing.expect(oauth.options.accepts_images);
    try std.testing.expectError(error.ModelNotAvailableWithChatGPT, f.route(&.{}, "openai", "gpt-4.1"));
    const listed = try f.list(&.{}, "openai");
    try std.testing.expectEqualStrings("openai", listed[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("gpt-5.5", listed[0].object.get("models").?.array.items[0].object.get("id").?.string);
    const text_only = try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(),
        \\{"gpt-5.5":{"modalities":{"input":["text"]},"attachment":false}}
    , .{});
    try std.testing.expect(!(try f.route(&.{.{ .id = "openai", .models = text_only }}, "openai", "gpt-5.5")).options.accepts_images);
    const keyed = try f.route(&.{.{ .id = "openai", .apiKey = "explicit-key" }}, "openai", "gpt-4.1");
    try std.testing.expectEqualStrings("openai-compatible", keyed.api);
    try std.testing.expectEqualStrings("explicit-key", keyed.options.apiKey.?);
    // A fresh credential is handed to the adapter only at request time.
    try platform.credentials.putOAuth(a, io, f.dir, "openai", .{
        .access = "fresh-access",
        .refresh = "refresh-secret",
        .expires = std.Io.Clock.real.now(io).toMilliseconds() + 3_600_000,
        .account_id = "account",
    });
    const auth = oauth.options.authentication.?;
    const value = try auth.resolve(auth.ctx, f.arena.allocator(), io);
    try std.testing.expectEqualStrings("fresh-access", value.apiKey);
    try std.testing.expectEqualStrings("account", value.account_id.?);
}

test "an explicit OpenAI key works even when saved credentials are unreadable" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    f.providers.data_dir = f.dir;
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "credentials.json", .data = "{not json" });
    const keyed = try f.route(&.{.{ .id = "openai", .apiKey = "explicit-key" }}, "openai", "gpt-4.1");
    try std.testing.expectEqualStrings("explicit-key", keyed.options.apiKey.?);
    try std.testing.expectEqual(@as(usize, 1), (try f.list(&.{.{ .id = "openai", .apiKey = "explicit-key" }}, "openai")).len);
}

test "the picker finds a provider through its own key variable when the catalog has none" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    try f.env.put("ZHIPU_API_KEY", "glm-key");
    const models_json = try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), "{\"glm-4.6\":{\"name\":\"GLM\"}}", .{});
    const listed = try f.list(&.{.{ .id = "zai", .models = models_json }}, "zai");
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("glm-4.6", listed[0].object.get("models").?.array.items[0].object.get("id").?.string);
}

test "a configured model's reasoning flag, thinking levels and default reach the route" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const a = f.arena.allocator();
    const overrides = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"thinker":{"reasoning":true,"thinkingLevels":["low","high","bogus"],"thinking":"high"},"plain":{}}
    , .{});
    const configured: []const Configured = &.{.{ .id = "local", .baseURL = "http://127.0.0.1:1/v1", .models = overrides }};
    const thinker = (try f.route(configured, "local", "thinker")).options;
    try std.testing.expect(thinker.reasoning);
    try std.testing.expect(thinker.thinking_levels.?.contains(.high) and !thinker.thinking_levels.?.contains(.medium));
    try std.testing.expectEqual(@import("proto").thinking.Level.high, thinker.thinking.?);
    try std.testing.expect(!(try f.route(configured, "local", "plain")).options.reasoning);
}
