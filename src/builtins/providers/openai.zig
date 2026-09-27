//! OpenAI: an API key uses Chat Completions; a ChatGPT sign-in (browser or
//! device code) uses the Codex Responses transport with the models a
//! ChatGPT plan can use. An explicit config key always wins over a sign-in.
const std = @import("std");
const plugin = @import("plugin");
const shared = @import("shared.zig");
const access = @import("access.zig");
const codex_models = @import("codex_models.zig");
const codex_api = @import("../provider_codex/root.zig");
const models = @import("../models.zig");
const oauth = @import("openai_oauth.zig");
const Allocator = std.mem.Allocator;
const Query = plugin.provider.Query;

pub const spec: shared.Spec = .{ .id = "openai", .name = "OpenAI", .env = &.{"OPENAI_API_KEY"}, .cache_key = true };

const methods = [_]plugin.provider.AuthMethod{
    .{ .id = "api", .label = "API key", .type = "api" },
    .{ .id = "browser", .label = "ChatGPT (browser)", .type = "oauth" },
    .{ .id = "device", .label = "ChatGPT (device code)", .type = "oauth" },
};

pub fn provider(ctx: *shared.Context) plugin.provider.Provider {
    return .{
        .id = spec.id,
        .name = spec.name,
        .auth_methods = &methods,
        .login = .{ .start = loginStart, .finish = loginFinish, .close = loginClose },
        .ctx = ctx,
        .resolve = resolve,
        .models = listing,
    };
}

fn resolve(raw: ?*anyopaque, arena: Allocator, io: std.Io, q: Query) anyerror!plugin.provider.Route {
    const ctx = shared.context(raw);
    if (!try usesOAuth(ctx, arena, io, q)) return shared.compatibleRoute(ctx, arena, io, q, spec);
    if (!codex_models.eligible(q.model)) return error.ModelNotAvailableWithChatGPT;
    var snapshot = try shared.catalogView(ctx, arena, q);
    defer snapshot.deinit();
    const available = try codex_models.view(arena, if (snapshot.provider(spec.id)) |p| p.models else &.{});
    var route: plugin.provider.Route = .{ .api = codex_api.api_id, .options = .{
        .baseURL = codex_api.default_base_url,
        .accepts_images = shared.acceptsImages(available, q.model),
        .context_window = shared.contextOf(available, q.model),
        .authentication = .{ .ctx = ctx, .resolve = resolveOAuth },
    } };
    shared.setThinking(&route.options, available, q.model);
    return route;
}

fn listing(raw: ?*anyopaque, arena: Allocator, io: std.Io, q: Query) anyerror![]const std.json.Value {
    const ctx = shared.context(raw);
    if (!try usesOAuth(ctx, arena, io, q)) return shared.listing(ctx, arena, io, q, spec, true);
    var snapshot = try shared.catalogView(ctx, arena, q);
    defer snapshot.deinit();
    var entry: models.Provider = if (snapshot.provider(spec.id)) |p| p.* else .{ .id = spec.id, .name = "OpenAI (ChatGPT)" };
    entry.models = try codex_models.view(arena, entry.models);
    entry.baseURL = codex_api.default_base_url;
    return arena.dupe(std.json.Value, &.{try shared.jsonValue(arena, entry)});
}

/// Disk-only lookup: image admission can call the resolver under its lock.
/// An explicit config key wins without reading saved credentials at all.
fn usesOAuth(ctx: *shared.Context, arena: Allocator, io: std.Io, q: Query) !bool {
    const configured = q.options(spec.id).apiKey;
    if (configured != null) return false;
    return access.usesOAuth(spec.id, configured, try shared.saved(ctx, arena, io));
}

/// Called by the adapter for every request, outside the runtime state lock.
fn resolveOAuth(raw: ?*anyopaque, arena: Allocator, io: std.Io) !plugin.provider.Credentials {
    const ctx = shared.context(raw);
    var value = (try oauth.access(arena, io, ctx.data_dir orelse return error.MissingCredentials)) orelse return error.MissingCredentials;
    defer value.deinit();
    return .{
        .apiKey = try arena.dupe(u8, value.access),
        .account_id = if (value.account_id) |id| try arena.dupe(u8, id) else null,
    };
}

fn loginStart(_: ?*anyopaque, arena: Allocator, io: std.Io, method: []const u8) anyerror!plugin.provider.Started {
    const which = std.meta.stringToEnum(oauth.Method, method) orelse return error.UnknownAuthMethod;
    const flow = try arena.create(oauth.Flow);
    flow.* = try oauth.start(arena, io, which);
    return .{ .url = flow.url, .instructions = flow.instructions, .state = flow };
}

fn loginFinish(_: ?*anyopaque, state: *anyopaque, arena: Allocator, io: std.Io) anyerror!plugin.provider.Tokens {
    const flow: *oauth.Flow = @ptrCast(@alignCast(state));
    const value = try flow.finish(arena, io);
    return .{ .access = value.access, .refresh = value.refresh, .expires = value.expires, .account_id = value.account_id };
}

fn loginClose(_: ?*anyopaque, state: *anyopaque, io: std.Io) void {
    const flow: *oauth.Flow = @ptrCast(@alignCast(state));
    flow.deinit(io);
}

test {
    _ = oauth;
    _ = @import("openai_oauth_http.zig");
}
