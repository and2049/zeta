const std = @import("std");
const core = @import("core");
const Server = @import("Server.zig");
const Ctx = @import("conn.zig").Ctx;
const query = @import("query.zig");

const AuthMethod = @import("plugin").provider.AuthMethod;
const Provider = struct { id: []const u8, name: []const u8, methods: []const AuthMethod };
const api_key = [_]AuthMethod{.{ .id = "api", .label = "API key", .type = "api" }};

pub fn dispatch(s: *Server, c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 2 and std.mem.eql(u8, seg[1], "providers")) {
        if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
        return providers(s, c);
    }
    if (seg.len == 3) {
        const provider = seg[1];
        if (std.mem.eql(u8, seg[2], "start")) {
            if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
            return start(s, c, provider);
        }
        if (std.mem.eql(u8, seg[2], "status")) {
            if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
            return status(s, c, provider);
        }
        if (std.mem.eql(u8, seg[2], "flow")) {
            if (c.method != .DELETE) return c.fail(.method_not_allowed, "method not allowed");
            return cancel(s, c, provider);
        }
    }
}

/// Registered providers with their login methods; with a location, also
/// the custom providers its config names.
fn providers(s: *Server, c: *Ctx) !void {
    const location = if (try query.get(c.arena, c.query, "location")) |raw| try core.location.resolve(c.arena, c.io, raw) else null;
    _ = try s.runtime.registry.activate(c.arena, location);
    const view = try s.runtime.registry.view(c.arena, location);
    var result: std.ArrayList(Provider) = .empty;
    for (view.providers) |p| {
        if (std.mem.eql(u8, p.value.id, "*")) continue;
        try result.append(c.arena, .{ .id = p.value.id, .name = p.value.name, .methods = p.value.auth_methods });
    }
    if (location) |here| {
        const cfg = try core.config.load(c.arena, c.io, s.runtime.env, s.runtime.config_dir, here);
        const fallback = view.provider("*");
        for (cfg.provider.map.keys()) |id| {
            if (registered(view, id)) continue;
            try result.append(c.arena, .{ .id = id, .name = id, .methods = if (fallback) |f| f.value.auth_methods else &api_key });
        }
    }
    try c.json(.ok, .{ .providers = result.items });
}

fn registered(view: @import("plugin").Registry.View, id: []const u8) bool {
    for (view.providers) |p| if (std.mem.eql(u8, p.value.id, id)) return true;
    return false;
}

/// `{"method", "location"?}`: starts the provider's sign-in for one of its
/// `oauth` methods. A location makes that project's provider plugins count,
/// and its configured custom providers resolve to the fallback registration
/// (as `/auth/providers` lists them).
fn start(s: *Server, c: *Ctx, provider: []const u8) !void {
    const body = try c.bodyJson(struct { method: []const u8, location: ?[]const u8 = null });
    const location = if (body.location) |raw| try core.location.resolve(c.arena, c.io, raw) else null;
    _ = try s.runtime.registry.activate(c.arena, location);
    const view = try s.runtime.registry.view(c.arena, location);
    const exact: ?@import("plugin").provider.Provider = for (view.providers) |p| {
        if (std.mem.eql(u8, p.value.id, provider)) break p.value;
    } else null;
    const found = exact orelse blk: {
        const here = location orelse return c.fail(.not_found, "provider not found");
        const cfg = try core.config.load(c.arena, c.io, s.runtime.env, s.runtime.config_dir, here);
        if (cfg.provider.map.get(provider) == null) return c.fail(.not_found, "provider not found");
        break :blk (view.provider("*") orelse return c.fail(.not_found, "provider not found")).value;
    };
    const login = found.login orelse return c.fail(.bad_request, "provider has no sign-in");
    const offered = for (found.auth_methods) |m| {
        if (std.mem.eql(u8, m.id, body.method) and std.mem.eql(u8, m.type, "oauth")) break true;
    } else false;
    if (!offered) return c.fail(.bad_request, "invalid auth method");
    const result = s.auth_flow.start(s.gpa, c.arena, c.io, s.data_dir, provider, login, body.method) catch |err| switch (err) {
        error.AuthUnavailable => return c.fail(.service_unavailable, "authentication unavailable"),
        else => |e| return e,
    };
    return c.json(.ok, .{ .id = try c.arena.dupe(u8, result.id), .url = try c.arena.dupe(u8, result.url), .instructions = try c.arena.dupe(u8, result.instructions) });
}

fn status(s: *Server, c: *Ctx, provider: []const u8) !void {
    const id = (try query.get(c.arena, c.query, "id")) orelse return c.fail(.bad_request, "missing flow id");
    const result = s.auth_flow.status(c.io, provider, id) orelse return c.fail(.not_found, "flow not found");
    return c.json(.ok, result);
}

fn cancel(s: *Server, c: *Ctx, provider: []const u8) !void {
    const id = (try query.get(c.arena, c.query, "id")) orelse return c.fail(.bad_request, "missing flow id");
    if (!try s.auth_flow.cancel(c.io, provider, id)) return c.fail(.not_found, "flow not found");
    return c.json(.ok, .{ .ok = true });
}
