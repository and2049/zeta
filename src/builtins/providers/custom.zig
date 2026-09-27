//! The fallback (`*`) for provider ids no registration claims: an
//! OpenAI-compatible endpoint described only by `provider.<id>` config
//! (`options.baseURL`, `options.apiKey`, `models`).
const std = @import("std");
const plugin = @import("plugin");
const shared = @import("shared.zig");
const access = @import("access.zig");
const Allocator = std.mem.Allocator;

pub fn provider(ctx: *shared.Context) plugin.provider.Provider {
    return .{ .id = "*", .name = "Custom", .auth_methods = &shared.api_key, .ctx = ctx, .resolve = resolve, .models = listing };
}

fn resolve(raw: ?*anyopaque, arena: Allocator, io: std.Io, q: plugin.provider.Query) anyerror!plugin.provider.Route {
    return shared.compatibleRoute(shared.context(raw), arena, io, q, .{ .id = q.provider, .name = q.provider });
}

/// Every configured provider the catalog does not know (the catalog only
/// keeps providers that have their own registration).
fn listing(raw: ?*anyopaque, arena: Allocator, io: std.Io, q: plugin.provider.Query) anyerror![]const std.json.Value {
    const ctx = shared.context(raw);
    var snapshot = try shared.catalogView(ctx, arena, q);
    defer snapshot.deinit();
    const saved = try shared.saved(ctx, arena, io);
    var out: std.ArrayList(std.json.Value) = .empty;
    for (snapshot.providers) |p| {
        if (ctx.catalog.keeps(p.id)) continue;
        const configured = q.options(p.id);
        if (!try access.connected(arena, configured, p, ctx.env, saved, false)) continue;
        var entry = p;
        if (configured.baseURL) |url| entry.baseURL = url;
        shared.redact(&entry);
        try out.append(arena, try shared.jsonValue(arena, entry));
    }
    return out.items;
}
