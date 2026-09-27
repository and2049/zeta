//! What the built-in providers share: the catalog view with config model
//! overrides, key lookup (config, stored credential, environment), and the
//! API-key route most providers use.
const std = @import("std");
const plugin = @import("plugin");
const platform = @import("platform");
const models = @import("../models.zig");
const access = @import("access.zig");
const openai_api = @import("../provider_openai/root.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Query = plugin.provider.Query;
const thinking = @import("proto").thinking;

/// Everything a built-in provider reads. Must outlive the registry.
pub const Context = struct {
    env: *const std.process.Environ.Map,
    catalog: *models.Catalog,
    data_dir: ?[]const u8 = null,
};

/// A provider served by one transport with an API key. The catalog's
/// endpoint and key variables win; these are used when it has none (e.g. a
/// first run while offline).
pub const Spec = struct {
    id: []const u8,
    name: []const u8,
    /// The transport; OpenAI-compatible unless set.
    api: []const u8 = openai_api.api_id,
    base_url: ?[]const u8 = null,
    env: []const []const u8 = &.{},
    /// Send the session id as a prompt-cache key unless config
    /// (`setCacheKey`) says otherwise.
    cache_key: bool = false,
};

pub const api_key = [_]plugin.provider.AuthMethod{.{ .id = "api", .label = "API key", .type = "api" }};

pub fn context(raw: ?*anyopaque) *Context {
    return @ptrCast(@alignCast(raw.?));
}

/// Catalog entries with config model overrides merged in; custom providers
/// appear from their overrides alone.
pub fn catalogView(ctx: *Context, arena: Allocator, q: Query) !models.Snapshot {
    var overrides: std.json.ArrayHashMap(std.json.Value) = .{};
    for (q.configured) |c| try overrides.map.put(arena, c.id, if (c.models == .object) c.models else .{ .object = .empty });
    return (try ctx.catalog.snapshot(arena, &overrides)).?;
}

/// Saved credential ids and types; never the secrets.
pub fn saved(ctx: *Context, arena: Allocator, io: Io) ![]const platform.credentials.Metadata {
    const dir = ctx.data_dir orelse return &.{};
    var list = try platform.credentials.list(arena, io, dir);
    const items = try arena.dupe(platform.credentials.Metadata, list.items);
    for (items) |*item| item.* = .{ .id = try arena.dupe(u8, item.id), .type = try arena.dupe(u8, item.type) };
    list.deinit();
    return items;
}

/// Endpoint, key and model limits for `spec` through its transport. Key
/// order: config, stored key, catalog or spec variables, then
/// `<ID>_API_KEY`. Without an endpoint the request fails rather than send a
/// key to the transport's default host.
pub fn compatibleRoute(ctx: *Context, arena: Allocator, io: Io, q: Query, spec: Spec) !plugin.provider.Route {
    var snapshot = try catalogView(ctx, arena, q);
    defer snapshot.deinit();
    const configured = q.options(q.provider);
    const listed = snapshot.provider(q.provider);
    var key = configured.apiKey orelse if (ctx.data_dir) |dir| try platform.credentials.readKey(arena, io, dir, q.provider) else null;
    if (key == null) key = firstEnv(ctx, if (listed) |p| p.env else &.{}) orelse firstEnv(ctx, spec.env);
    const base_url = configured.baseURL orelse
        (if (listed) |p| if (p.baseURL) |url| try arena.dupe(u8, url) else null else null) orelse spec.base_url;
    if (base_url == null and !std.mem.eql(u8, q.provider, "openai")) return error.ProviderEndpointUnknown;
    var route: plugin.provider.Route = .{ .api = spec.api, .options = .{
        .baseURL = base_url,
        .apiKey = key orelse try genericKey(ctx, arena, q.provider),
        .accepts_images = if (listed) |p| acceptsImages(p.models, q.model) else false,
        .context_window = if (listed) |p| contextOf(p.models, q.model) else 0,
        .max_output = if (listed) |p| outputOf(p.models, q.model) else 0,
        .cache_key = configured.setCacheKey orelse spec.cache_key,
        .price = if (listed) |p| priceOf(p.models, q.model) else null,
    } };
    if (listed) |p| setThinking(&route.options, p.models, q.model);
    return route;
}

/// The model's context window from the catalog; 0 when unknown.
/// The model's price, when the catalog or config gives one.
pub fn priceOf(list: []const models.Model, id: []const u8) ?@import("proto").message.Price {
    for (list) |model| if (std.mem.eql(u8, model.id, id)) {
        const c = model.cost;
        if (c.input == 0 and c.output == 0 and c.cache_read == 0 and c.cache_write == 0) return null;
        return .{ .input = c.input, .output = c.output, .cacheRead = c.cache_read, .cacheWrite = c.cache_write };
    };
    return null;
}

pub fn contextOf(list: []const models.Model, id: []const u8) u64 {
    for (list) |model| if (std.mem.eql(u8, model.id, id)) return model.context;
    return 0;
}

/// The model's reasoning flag, and from config its thinking levels and
/// default. Unknown level names are ignored.
pub fn setThinking(options: *plugin.provider.Options, list: []const models.Model, id: []const u8) void {
    for (list) |model| {
        if (!std.mem.eql(u8, model.id, id)) continue;
        options.reasoning = model.reasoning;
        if (model.thinking_levels.len > 0) {
            var levels: thinking.Set = .initEmpty();
            for (model.thinking_levels) |name| if (thinking.Level.parse(name)) |l| levels.insert(l);
            options.thinking_levels = levels;
        }
        options.thinking = if (model.thinking) |name| thinking.Level.parse(name) else null;
        return;
    }
}

/// Config's `reasoning`, `thinkingLevels` and `thinking` for one model (a
/// `provider.<id>.models.<model>` object), for providers without a catalog.
pub fn thinkingOverride(options: *plugin.provider.Options, override: std.json.Value) void {
    if (override != .object) return;
    const o = override.object;
    if (o.get("reasoning")) |r| if (r == .bool) {
        options.reasoning = r.bool;
    };
    if (o.get("thinkingLevels")) |list| if (list == .array) {
        var levels: thinking.Set = .initEmpty();
        for (list.array.items) |item| if (item == .string) if (thinking.Level.parse(item.string)) |l| levels.insert(l);
        options.thinking_levels = levels;
    };
    if (o.get("thinking")) |t| if (t == .string) {
        options.thinking = thinking.Level.parse(t.string);
    };
}

/// The model's output limit from the catalog; 0 when unknown.
pub fn outputOf(list: []const models.Model, id: []const u8) u64 {
    for (list) |model| if (std.mem.eql(u8, model.id, id)) return model.output_limit;
    return 0;
}

/// The picker entry for one provider, when it is connected.
pub fn listing(ctx: *Context, arena: Allocator, io: Io, q: Query, spec: Spec, oauth: bool) ![]const std.json.Value {
    var snapshot = try catalogView(ctx, arena, q);
    defer snapshot.deinit();
    const known = snapshot.provider(spec.id);
    var entry: models.Provider = if (known) |p| p.* else .{ .id = spec.id, .name = spec.name };
    const configured = q.options(spec.id);
    // Key variables as routing reads them: the catalog's, then the spec's.
    var probe = entry;
    probe.env = try std.mem.concat(arena, []const u8, &.{ entry.env, spec.env });
    // An explicit key or endpoint decides without reading saved credentials.
    const stored = if (configured.apiKey != null or configured.baseURL != null) &.{} else try saved(ctx, arena, io);
    if (!try access.connected(arena, configured, probe, ctx.env, stored, oauth)) return &.{};
    if (configured.baseURL) |url| entry.baseURL = url;
    if (entry.baseURL == null) entry.baseURL = spec.base_url;
    redact(&entry);
    return arena.dupe(std.json.Value, &.{try jsonValue(arena, entry)});
}

pub fn redact(entry: *models.Provider) void {
    if (entry.baseURL) |url| if (std.mem.indexOfAny(u8, url, "@?#") != null) {
        entry.baseURL = "[REDACTED]";
    };
}

fn firstEnv(ctx: *Context, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (ctx.env.get(name)) |value| return value;
    return null;
}

fn genericKey(ctx: *Context, arena: Allocator, provider_id: []const u8) !?[]const u8 {
    const name = try std.fmt.allocPrint(arena, "{s}_API_KEY", .{provider_id});
    for (name) |*c| c.* = if (c.* == '-') '_' else std.ascii.toUpper(c.*);
    return ctx.env.get(name);
}

pub fn jsonValue(arena: Allocator, value: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, value, .{}), .{ .allocate = .alloc_always });
}

pub fn acceptsImages(list: []const models.Model, id: []const u8) bool {
    for (list) |model| {
        if (!std.mem.eql(u8, model.id, id)) continue;
        if (model.modalities_input.len == 0) return model.attachment;
        for (model.modalities_input) |modality| if (std.mem.eql(u8, modality, "image")) return true;
        return false;
    }
    return false;
}
