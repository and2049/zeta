//! A provider that is one endpoint with an API key, on the transport its
//! `Spec` names (OpenAI-compatible unless set); most providers are one `Spec`
//! passed to `provider`.
const std = @import("std");
const plugin = @import("plugin");
const shared = @import("shared.zig");
const Allocator = std.mem.Allocator;

/// The registration for `spec`; its ctx must be a `*shared.Context`.
pub fn provider(comptime spec: shared.Spec, ctx: *shared.Context) plugin.provider.Provider {
    const Impl = struct {
        fn resolve(raw: ?*anyopaque, arena: Allocator, io: std.Io, q: plugin.provider.Query) anyerror!plugin.provider.Route {
            return shared.compatibleRoute(shared.context(raw), arena, io, q, spec);
        }
        fn listing(raw: ?*anyopaque, arena: Allocator, io: std.Io, q: plugin.provider.Query) anyerror![]const std.json.Value {
            return shared.listing(shared.context(raw), arena, io, q, spec, false);
        }
    };
    return .{ .id = spec.id, .name = spec.name, .auth_methods = &shared.api_key, .ctx = ctx, .resolve = Impl.resolve, .models = Impl.listing };
}
