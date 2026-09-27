//! Test-only provider: routes every model to the transport `api_id` with the
//! configured endpoint and key.
const std = @import("std");
const plugin = @import("plugin");

pub const api_id = "openai-compatible";

pub fn register(r: *plugin.Registry) !void {
    try r.addProvider(try r.addPlugin(.{ .id = "test-provider" }), .{ .id = "*", .name = "Test", .resolve = resolve });
}

fn resolve(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, q: plugin.provider.Query) anyerror!plugin.provider.Route {
    return .{ .api = api_id, .options = .{ .baseURL = q.options(q.provider).baseURL, .apiKey = q.options(q.provider).apiKey } };
}
